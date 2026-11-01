import Foundation

nonisolated struct GatewayHTTPResponse: Sendable {
    let status: Int
    let url: URL
    let data: Data
}

nonisolated protocol GatewayTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> GatewayHTTPResponse
}

private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated struct URLSessionGatewayTransport: GatewayTransport {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> GatewayHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let url = response.url,
                  response.expectedContentLength <= Int64(maximumResponseBytes) else {
                throw GatewayError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { throw GatewayError.responseTooLarge }
                data.append(byte)
            }
            return GatewayHTTPResponse(status: response.statusCode, url: url, data: data)
        } catch let error as GatewayError { throw error }
        catch { throw GatewayError.transport }
    }
}

nonisolated struct GatewayClient: Sendable {
    let origin: String
    let expectedEnvironment: EntitlementEnvironment?
    private let baseURL: URL
    private let transport: any GatewayTransport
    static let maximumResponseBytes = 262_144

    init(baseURL: URL?, transport: any GatewayTransport = URLSessionGatewayTransport(),
         expectedEnvironment: EntitlementEnvironment? = nil) throws {
        guard let baseURL else { throw GatewayError.unavailable }
        guard let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port == nil || c.port == 443,
              host == host.lowercased(), host.utf8.allSatisfy({ $0 < 128 })
        else { throw GatewayError.invalidConfiguration }
        self.origin = "https://" + host
        guard let canonical = URL(string: origin) else { throw GatewayError.invalidConfiguration }
        self.baseURL = canonical
        self.transport = transport
        self.expectedEnvironment = expectedEnvironment
    }

    func request<Response: Decodable & Sendable>(
        _ method: String, path: String, bearer: String? = nil, body: Data? = nil,
        as type: Response.Type = Response.self, timeout: TimeInterval = 30
    ) async throws -> Response {
        let response = try await send(method, path: path, bearer: bearer, body: body, timeout: timeout)
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: response.data)
        } catch { throw GatewayError.invalidResponse }
    }

    func empty(_ method: String, path: String, bearer: String, body: Data? = nil) async throws {
        let response = try await send(method, path: path, bearer: bearer, body: body, timeout: 30)
        guard response.status == 204, response.data.isEmpty else { throw GatewayError.invalidResponse }
    }

    private func send(_ method: String, path: String, bearer: String?, body: Data?, timeout: TimeInterval) async throws -> GatewayHTTPResponse {
        guard path.hasPrefix("/v1/"), !path.contains(".."),
              path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [45, 47, 95].contains($0) }),
              (1...90).contains(timeout),
              ["GET", "POST", "PUT", "DELETE"].contains(method)
        else { throw GatewayError.invalidInput }
        let rendering = path == "/v1/render/quotes" || path == "/v1/render/jobs" || path.hasPrefix("/v1/render/jobs/")
        let responseLimit = rendering ? 12 * 1024 * 1024 : Self.maximumResponseBytes
        guard (body?.count ?? 0) <= (rendering ? 12 * 1024 * 1024 : 65_536) else { throw GatewayError.invalidInput }
        if let bearer { try StoredAccount(accountID: UUID(), bearer: bearer).validate() }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())), timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let response: GatewayHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: responseLimit) }
        catch let error as GatewayError { throw error }
        catch { throw GatewayError.transport }
        guard response.url == request.url, response.data.count <= responseLimit else {
            throw GatewayError.invalidResponse
        }
        guard (200...299).contains(response.status) else {
            if response.status == 401 { throw GatewayError.unauthorized }
            throw GatewayError.server(response.status)
        }
        return response
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let data = try encoder.encode(value)
            guard data.count <= 65_536 else { throw GatewayError.invalidInput }
            return data
        } catch { throw GatewayError.invalidInput }
    }
}

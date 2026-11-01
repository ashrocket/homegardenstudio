import Foundation

nonisolated struct LocalModelConfiguration: Sendable, Equatable {
    let endpoint: URL
    let model: String
    init(endpoint: String, model: String) throws {
        guard let url = URL(string: endpoint), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(c.host?.lowercased() ?? ""),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true,
              !c.path.isEmpty, c.path != "/", endpoint.utf8.count <= 2048 else { throw LocalAIError.invalidEndpoint }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200, !model.contains(where: { $0.isNewline || $0 == "\0" }) else { throw LocalAIError.invalidModel }
        self.endpoint = url; self.model = model
    }
}
nonisolated protocol LocalModelTransport: Sendable { func send(_ request: URLRequest) async throws -> Data }
nonisolated struct LoopbackModelTransport: LocalModelTransport {
    @concurrent func send(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw LocalAIError.invalidEndpoint }
        _ = try LocalModelConfiguration(endpoint: url.absoluteString, model: "validation")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoLocalRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url,
                  response.mimeType?.lowercased() == "application/json" else { throw LocalAIError.invalidResponse }
            guard response.expectedContentLength <= 256 * 1024 else { throw LocalAIError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { throw LocalAIError.responseTooLarge }
                data.append(byte)
            }
            return data
        } catch let error as LocalAIError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalAIError.failed }
    }
}
nonisolated private final class NoLocalRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
nonisolated enum LoopbackAssistant {
    static func respond(configuration: LocalModelConfiguration, prompt: String, transport: any LocalModelTransport) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Input: Encodable { let model: String; let messages: [Message]; let stream: Bool; let max_tokens: Int }
        struct Output: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        guard prompt.utf8.count <= 16_000 else { throw LocalAIError.oversizedInput }
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Input(model: configuration.model, messages: [Message(role: "system", content: AssistantPrompt.instructions), Message(role: "user", content: prompt)], stream: false, max_tokens: 800))
        let data = try await transport.send(request)
        guard data.count <= 256 * 1024 else { throw LocalAIError.responseTooLarge }
        guard let result = try? JSONDecoder().decode(Output.self, from: data), let text = result.choices.first?.message.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 48_000 else { throw LocalAIError.invalidResponse }
        return text
    }
}

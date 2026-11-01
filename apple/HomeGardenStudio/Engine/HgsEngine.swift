import Foundation
import HgsCore

nonisolated struct EngineError: Error, Codable, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { "\(message) (\(code))" }
}
nonisolated enum EngineCodec {
    static func strictUTF8(_ data: Data) throws -> String {
        guard !data.contains(0), let string = String(data: data, encoding: .utf8) else {
            throw EngineError(code: "INVALID_JSON", message: "Plan JSON must be valid UTF-8 without embedded NUL bytes.")
        }
        return string
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e }
    static func consume(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw EngineError(code: "INTERNAL", message: "The layout engine returned no response.") }
        defer { hgs_string_free(pointer) }
        return Data(String(cString: pointer).utf8)
    }
    static func check(_ data: Data) throws {
        struct Envelope: Decodable { let ok: Bool; let error: EngineError? }
        let envelope = try decoder().decode(Envelope.self, from: data)
        if !envelope.ok { throw envelope.error ?? EngineError(code: "INTERNAL", message: "Unknown engine error.") }
    }
    /// This short-lived engine is confined to the calling thread, including document I/O queues.
    static func canonicalSnapshot(_ json: Data? = nil, name: String = "Untitled plan") throws -> Data {
        var error: UnsafeMutablePointer<CChar>?
        let handle: OpaquePointer?
        if let json { handle = try strictUTF8(json).withCString { hgs_engine_open($0, &error) } }
        else { handle = name.withCString { hgs_engine_new($0) } }
        defer { if let error { hgs_string_free(error) } }
        guard let handle else {
            if let error { let data = Data(String(cString: error).utf8); try check(data) }
            throw EngineError(code: "INVALID_JSON", message: "This plan could not be opened.")
        }
        defer { hgs_engine_free(handle) }
        let data = try consume("{\"q\":\"snapshot\"}".withCString { hgs_engine_query(handle, $0) })
        try check(data)
        struct Envelope: Decodable { let result: JSONValue }
        return try encoder().encode(decoder().decode(Envelope.self, from: data).result)
    }
}

@MainActor final class HgsEngine {
    private let handle: OpaquePointer
    init(name: String) {
        guard let handle = name.withCString({ hgs_engine_new($0) }) else { fatalError("Unable to allocate the layout engine") }
        self.handle = handle
    }
    init(json: Data) throws {
        var error: UnsafeMutablePointer<CChar>?
        let handle = try EngineCodec.strictUTF8(json).withCString { hgs_engine_open($0, &error) }
        defer { if let error { hgs_string_free(error) } }
        guard let handle else {
            if let error { try EngineCodec.check(Data(String(cString: error).utf8)) }
            throw EngineError(code: "INVALID_JSON", message: "This plan could not be opened.")
        }
        self.handle = handle
    }
    isolated deinit { hgs_engine_free(handle) }
    func command(_ command: EngineCommand) -> Result<CommandResponse, EngineError> {
        result {
            let json = String(decoding: try EngineCodec.encoder().encode(command), as: UTF8.self)
            let data = try EngineCodec.consume(json.withCString { hgs_engine_command(handle, $0) })
            try EngineCodec.check(data)
            return try EngineCodec.decoder().decode(CommandResponse.self, from: data)
        }
    }
    func query<T: Decodable>(_ query: EngineQuery, as type: T.Type = T.self) -> Result<T, EngineError> {
        result {
            let json = String(decoding: try EngineCodec.encoder().encode(query), as: UTF8.self)
            let data = try EngineCodec.consume(json.withCString { hgs_engine_query(handle, $0) })
            try EngineCodec.check(data)
            return try EngineCodec.decoder().decode(QueryEnvelope<T>.self, from: data).result
        }
    }
    func snapshot() throws -> Data { try EngineCodec.encoder().encode(query(EngineQuery("snapshot"), as: JSONValue.self).get()) }
    private func result<T>(_ operation: () throws -> T) -> Result<T, EngineError> {
        do { return .success(try operation()) }
        catch let error as EngineError { return .failure(error) }
        catch { return .failure(EngineError(code: "INVALID_JSON", message: error.localizedDescription)) }
    }
}
nonisolated private struct QueryEnvelope<T: Decodable>: Decodable { let result: T }

import Foundation
import UniformTypeIdentifiers

nonisolated enum DropImport {
    static let maximumItems = 8
    static let acceptedTypes = [UTType.fileURL, .url, .image, .pdf]
    static func validateCount(_ count: Int) throws {
        guard (1...maximumItems).contains(count) else { throw EngineError(code: "DROP_LIMIT", message: "Drop up to eight images, PDFs or page links at a time.") }
    }
    static func validatedURL(_ url: URL) throws -> URL {
        guard url.absoluteString.utf8.count <= 2000, url.user == nil, url.password == nil else { throw invalidURL }
        if url.isFileURL {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) || type.conforms(to: .pdf) else { throw invalidURL }
        } else {
            guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw invalidURL }
        }
        return url
    }
    static func parseURL(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\0"), let url = URL(string: text) else { throw invalidURL }
        return try validatedURL(url)
    }
    static var invalidURL: EngineError { EngineError(code: "UNSUPPORTED_DROP", message: "Drop an image or PDF file, or an HTTPS page link without credentials. Plan packages and JSON must be opened explicitly.") }

    /// File representations are consumed inside their callback, while the provider's temporary file is valid.
    @MainActor static func prepare(_ provider: NSItemProvider) async throws -> PreparedImport {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let identifier = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        let url: URL
                        if let value = item as? URL { url = try validatedURL(value) }
                        else if let value = item as? String { url = try parseURL(value) }
                        else if let data = item as? Data, data.count <= 8192, let value = String(data: data, encoding: .utf8) { url = try parseURL(value) }
                        else { throw invalidURL }
                        continuation.resume(returning: url)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if url.isFileURL { return try await Task.detached { try ImportService.file(url) }.value }
            return try await ImportService.url(url.absoluteString)
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }; return type.conforms(to: .image) || type.conforms(to: .pdf)
        }) else { throw invalidURL }
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw invalidURL }
                    var prepared = try ImportService.file(url, typeHint: UTType(identifier))
                    if let name, !name.isEmpty { prepared.source.title = String(name.prefix(300)); prepared.source.originalFilename = String(name.prefix(300)) }
                    continuation.resume(returning: prepared)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

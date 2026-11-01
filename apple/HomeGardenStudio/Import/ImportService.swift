import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PreparedImport: Sendable { var source: Source; var bytes: Data; var storageName: String }
nonisolated enum ImportService {
    static let maxFileBytes = 40 * 1024 * 1024
    static func file(_ url: URL, typeHint: UTType? = nil) throws -> PreparedImport {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true else { throw EngineError(code: "UNSUPPORTED_FILE", message: "Choose a regular image or PDF file.") }
        let size = attributes.fileSize ?? 0
        guard size <= maxFileBytes else { throw EngineError(code: "IMPORT_LIMIT", message: "Choose a file smaller than 40 MB.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        return try prepare(data, filename: url.lastPathComponent, type: typeHint ?? UTType(filenameExtension: url.pathExtension))
    }
    static func prepare(_ data: Data, filename: String, type: UTType?) throws -> PreparedImport {
        guard !data.isEmpty, data.count <= maxFileBytes else { throw EngineError(code: "IMPORT_LIMIT", message: "Choose a nonempty file smaller than 40 MB.") }
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil).flatMap { source -> CGImageSource? in
            guard let identifier = CGImageSourceGetType(source), let detected = UTType(identifier as String),
                  detected.conforms(to: .image), CGImageSourceGetCount(source) > 0,
                  CGImageSourceGetStatus(source) == .statusComplete else { return nil }
            return source
        }
        let detected = imageSource.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        let resolved = detected ?? type ?? .data
        guard imageSource != nil || (resolved.conforms(to: .pdf) && data.starts(with: Data("%PDF-".utf8))) else { throw EngineError(code: "UNSUPPORTED_FILE", message: "Choose an image or PDF.") }
        let props = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = resolved.preferredFilenameExtension ?? "bin"
        let source = Source(id: "src-" + sha.prefix(16), kind: imageSource == nil ? "file" : "photo", title: filename, originalFilename: filename, sha256: sha, byteCount: data.count, mediaType: resolved.preferredMIMEType, url: nil, pixelWidth: props?[kCGImagePropertyPixelWidth] as? Int, pixelHeight: props?[kCGImagePropertyPixelHeight] as? Int, registration: nil, note: "Imported original. No position or survey accuracy inferred.")
        return PreparedImport(source: source, bytes: data, storageName: sha + "." + ext)
    }
    @concurrent static func url(_ value: String) async throws -> PreparedImport {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw EngineError(code: "INVALID_URL", message: "Enter an HTTPS page URL without credentials.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 10))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.url?.scheme == "https" else { throw EngineError(code: "HTTP_ERROR", message: "The page could not be imported.") }
        guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw EngineError(code: "IMPORT_LIMIT", message: "The page exceeds the 2 MB import limit.") }
        var data = Data()
        for try await byte in stream { guard data.count < 2 * 1024 * 1024 else { throw EngineError(code: "IMPORT_LIMIT", message: "The page exceeds the 2 MB import limit.") }; data.append(byte) }
        let title = extractTitle(String(decoding: data, as: UTF8.self)) ?? url.host ?? "Web source"
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let source = Source(id: "src-" + sha.prefix(16), kind: "url", title: title, originalFilename: "source.html", sha256: sha, byteCount: data.count, mediaType: response.mimeType ?? "text/html", url: response.url?.absoluteString ?? value, pixelWidth: nil, pixelHeight: nil, registration: nil, note: "Page metadata only. No linked images downloaded; dimensions and positions are unverified.")
        return PreparedImport(source: source, bytes: data, storageName: sha + ".html")
    }
    static func extractTitle(_ html: String) -> String? {
        let patterns = [#"<meta\b[^>]*property\s*=\s*["']og:title["'][^>]*content\s*=\s*["']([^"']+)["']"#, #"<meta\b[^>]*content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:title["']"#, #"<title\b[^>]*>([\s\S]*?)</title>"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) else { continue }
            let title = String(html[range]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return String(title.prefix(300)) }
        }
        return nil
    }
}
nonisolated private final class HTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.user == nil && request.url?.password == nil ? request : nil)
    }
}

nonisolated enum LengthFormatter {
    static func format(_ meters: Double, units: String) -> String {
        if units == "metric" { return String(format: "%.2f m", meters) }
        let sign = meters < 0 ? "−" : ""
        let inches = Int((abs(meters) / 0.0254).rounded())
        return "\(sign)\(inches / 12) ft \(inches % 12) in"
    }
    static func parse(_ text: String, units: String) -> Double? {
        let s = text.lowercased().replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Double(s) { return v.isFinite ? v * (units == "metric" ? 1 : 0.3048) : nil }
        let pattern = #"^\s*([+-]?\d+(?:\.\d+)?)\s*(m|cm|ft|in|'|\")\s*(?:(\d+(?:\.\d+)?)\s*(in|\"))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let n = Range(match.range(at: 1), in: s), let u = Range(match.range(at: 2), in: s), let value = Double(s[n]) else { return nil }
        let unit = String(s[u]); let extra = Range(match.range(at: 3), in: s).flatMap { Double(s[$0]) } ?? 0
        if extra != 0 && unit != "ft" && unit != "'" { return nil }
        let factor: Double = unit == "m" ? 1 : unit == "cm" ? 0.01 : (unit == "ft" || unit == "'") ? 0.3048 : 0.0254
        return value * factor + (value < 0 ? -extra : extra) * 0.0254
    }
}

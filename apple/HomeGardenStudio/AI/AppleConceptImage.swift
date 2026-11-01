import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

/// Image Playground has no layout fidelity guarantee. This records the inputs supplied
/// by the app, not edits the person may make inside Apple's system sheet.
nonisolated enum AppleConceptImage {
    static let maxBytes = 40 * 1024 * 1024
    static let maxPixels = 8_388_608
    static let provider = "Apple Image Playground"

    struct Input: Sendable {
        let projectID: UUID
        let prompt: String
        let layoutPNG: Data
        let photoPNG: Data?
        let digest: String

        init(projectID: UUID, projectJSON: Data, prompt: String, layoutPNG: Data, photoPNG: Data?) throws {
            guard !projectJSON.isEmpty, projectJSON.count <= 8 * 1024 * 1024,
                  !prompt.isEmpty, prompt.utf8.count <= 32_768,
                  !layoutPNG.isEmpty, layoutPNG.count <= maxBytes,
                  photoPNG.map({ !$0.isEmpty && $0.count <= maxBytes }) ?? true else { throw Failure.invalidInput }
            self.projectID = projectID; self.prompt = prompt; self.layoutPNG = layoutPNG; self.photoPNG = photoPNG
            var hash = SHA256()
            for part in [Data("Apple Image Playground input v1".utf8), Data(projectID.uuidString.utf8), projectJSON,
                         Data(prompt.utf8), layoutPNG, photoPNG ?? Data()] {
                var size = UInt64(part.count).bigEndian
                withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
                hash.update(data: part)
            }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Failure: LocalizedError {
        case invalidInput, invalidFile, tooLarge, invalidImage, wrongDocument, storageLimit, storageFailure
        var errorDescription: String? {
            switch self {
            case .invalidInput: "The concept inputs are missing or too large. Prepare them again."
            case .invalidFile: "Apple's completed image could not be read as a regular local file."
            case .tooLarge: "The image exceeds 40 MB, a 4096-pixel edge, or 8 megapixels."
            case .invalidImage: "The completed image is incomplete or cannot be converted to PNG."
            case .wrongDocument: "The open plan changed. This concept was not added to a different document."
            case .storageLimit: "This plan's image storage limit was reached. The concept was not added."
            case .storageFailure: "The concept could not be added to this plan. No saved copy is confirmed."
            }
        }
    }

    /// The descriptor pins Apple's temporary file before its sheet is dismissed.
    /// This type is single-consumer: only normalize() reads it, in a detached task.
    final class OpenedFile: @unchecked Sendable {
        private let file: FileHandle
        private let lock = NSLock()
        private var consumed = false
        init(url: URL) throws {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw Failure.invalidFile }
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } ?? -1
            }
            guard descriptor >= 0 else { throw Failure.invalidFile }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                close(descriptor); throw Failure.invalidFile
            }
            guard metadata.st_size > 0, metadata.st_size <= Int64(maxBytes) else {
                close(descriptor); throw Failure.tooLarge
            }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        func normalize() throws -> Data {
            guard lock.withLock({ if consumed { return false }; consumed = true; return true }) else { throw Failure.invalidFile }
            defer { try? file.close() }
            guard let bytes = try file.read(upToCount: maxBytes + 1) else { throw Failure.invalidFile }
            return try normalizedPNG(bytes)
        }
    }

    static func normalizedPNG(_ bytes: Data) throws -> Data {
        let image = try decodedImage(bytes)
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, image, nil) // Do not copy EXIF, GPS, or source metadata.
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        guard CFDataGetLength(output) <= maxBytes else { throw Failure.tooLarge }
        return output as Data
    }

    static func decodedImage(_ bytes: Data) throws -> CGImage {
        guard !bytes.isEmpty, bytes.count <= maxBytes else { throw Failure.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to: .image),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.invalidImage }
        guard (1...4096).contains(width), (1...4096).contains(height), width <= maxPixels / height else { throw Failure.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary), image.width <= 4096, image.height <= 4096,
              image.width <= maxPixels / max(1, image.height) else { throw Failure.invalidImage }
        return image
    }

    @MainActor @discardableResult static func attach(_ png: Data, input: Input, to document: PlanDocument) throws -> RenderAttachmentRecord {
        guard input.projectID == document.projectID else { throw Failure.wrongDocument }
        let filename = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png"
        let record = RenderAttachmentRecord(id: UUID(), projectID: input.projectID, filename: filename,
            title: "Apple concept — approximate, not measured", provider: provider, inputDigest: input.digest, createdAt: Date())
        do { try document.attachRender(png, record: record) }
        catch let error as EngineError where error.code == "IMPORT_LIMIT" { throw Failure.storageLimit }
        catch { throw Failure.storageFailure }
        return record
    }
}

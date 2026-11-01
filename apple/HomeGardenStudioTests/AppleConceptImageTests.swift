import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
#if HGS_APPLE_ONLY
@testable import HomeGardenStudioApple
#else
@testable import HomeGardenStudio
#endif

nonisolated final class AppleConceptImageTests: XCTestCase {
    private func fixture(width: Int = 8, height: Int = 6) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage()), data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGComment: "Synthetic private source note"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "HGS-AppleConceptTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testNormalizesPixelsToPNGWithoutSourceMetadata() async throws {
        let original = try fixture()
        let png = try await Task.detached { try AppleConceptImage.normalizedPNG(original) }.value
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 6)
        XCTAssertNil((properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGComment])
    }

    func testRejectsInvalidTruncatedAndOversizedImages() throws {
        XCTAssertThrowsError(try AppleConceptImage.normalizedPNG(Data("not an image".utf8)))
        let png = try fixture()
        XCTAssertThrowsError(try AppleConceptImage.normalizedPNG(png.prefix(24)))
        XCTAssertThrowsError(try AppleConceptImage.normalizedPNG(fixture(width: 4097, height: 1)))
        XCTAssertThrowsError(try AppleConceptImage.normalizedPNG(fixture(width: 4096, height: 2049)))
    }

    func testRejectsRemoteURLSymlinkDirectoryAndOversizedFile() throws {
        let folder = try directory(), file = folder.appending(path: "image.png"), link = folder.appending(path: "link.png")
        try fixture().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AppleConceptImage.OpenedFile(url: URL(string: "https://example.invalid/image.png")!))
        XCTAssertThrowsError(try AppleConceptImage.OpenedFile(url: link))
        XCTAssertThrowsError(try AppleConceptImage.OpenedFile(url: folder))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AppleConceptImage.maxBytes + 1)); try handle.close()
        XCTAssertThrowsError(try AppleConceptImage.OpenedFile(url: file))
    }

    func testPinsTemporaryFileBeforeAsynchronousDecodeAndConsumesOnce() async throws {
        let file = try directory().appending(path: "completed.png")
        try fixture().write(to: file)
        let opened = try AppleConceptImage.OpenedFile(url: file)
        try FileManager.default.removeItem(at: file)
        let png = try await Task.detached { try opened.normalize() }.value
        XCTAssertNotNil(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertThrowsError(try opened.normalize())
    }

    func testDigestBindsProjectTextAndOptionalPhoto() throws {
        let id = UUID(), png = try fixture()
        func input(_ json: String = "{}", _ prompt: String = "Garden", _ photo: Data? = nil, projectID: UUID? = nil) throws -> AppleConceptImage.Input {
            try .init(projectID: projectID ?? id, projectJSON: Data(json.utf8), prompt: prompt, layoutPNG: png, photoPNG: photo)
        }
        let baseline = try input()
        XCTAssertEqual(baseline.digest, try input().digest)
        XCTAssertNotEqual(baseline.digest, try input("{\"changed\":true}").digest)
        XCTAssertNotEqual(baseline.digest, try input("{}", "Different look").digest)
        XCTAssertNotEqual(baseline.digest, try input("{}", "Garden", png).digest)
        XCTAssertNotEqual(baseline.digest, try input(projectID: UUID()).digest)
        XCTAssertThrowsError(try input("{}", String(repeating: "a", count: 32_769)))
    }

    @MainActor func testAttachmentRetainsFrozenProvenanceAndRoundTrips() throws {
        let document = PlanDocument(), png = try AppleConceptImage.normalizedPNG(fixture())
        let frozen = try document.snapshot(contentType: .gardenPlan).project
        let input = try AppleConceptImage.Input(projectID: document.projectID, projectJSON: frozen, prompt: "Synthetic garden", layoutPNG: png, photoPNG: nil)
        let store = try PlanStore(document: document)
        store.add("plant", undoManager: nil) // Edits do not rewrite the frozen provenance.
        let current = try document.snapshot(contentType: .gardenPlan).project
        XCTAssertNotEqual(current, frozen)
        let record = try AppleConceptImage.attach(png, input: input, to: document)
        XCTAssertEqual(record.provider, "Apple Image Playground")
        XCTAssertEqual(record.inputDigest, input.digest)
        XCTAssertTrue(record.title.contains("not measured"))
        XCTAssertEqual(record.filename, SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() + ".png")
        let reopened = try PlanDocument.read(PlanDocument.package(document.snapshot(contentType: .gardenPlan)))
        XCTAssertEqual(reopened.project, current)
        XCTAssertEqual(reopened.renderRecords.first?.inputDigest, input.digest)
        XCTAssertEqual(reopened.renders[record.filename], png)
    }

    @MainActor func testWrongDocumentAndStorageFailurePreservePlan() throws {
        let original = PlanDocument(), other = PlanDocument(), png = try AppleConceptImage.normalizedPNG(fixture())
        let json = try original.snapshot(contentType: .gardenPlan).project
        let input = try AppleConceptImage.Input(projectID: original.projectID, projectJSON: json, prompt: "Garden", layoutPNG: png, photoPNG: nil)
        let before = try other.snapshot(contentType: .gardenPlan)
        XCTAssertThrowsError(try AppleConceptImage.attach(png, input: input, to: other))
        XCTAssertEqual(try other.snapshot(contentType: .gardenPlan).project, before.project)
        XCTAssertTrue(other.renderRecords.isEmpty)
        let full = try PlanDocument(project: json, attachmentLimit: 1)
        let boundedInput = try AppleConceptImage.Input(projectID: full.projectID, projectJSON: json, prompt: "Garden", layoutPNG: png, photoPNG: nil)
        XCTAssertThrowsError(try AppleConceptImage.attach(png, input: boundedInput, to: full)) { error in
            XCTAssertFalse(error.localizedDescription.contains("recovery"))
        }
        XCTAssertTrue(full.renderRecords.isEmpty)
        XCTAssertEqual(try full.snapshot(contentType: .gardenPlan).project, json)
    }
}

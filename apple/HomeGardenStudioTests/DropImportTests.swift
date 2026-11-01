import XCTest
import UniformTypeIdentifiers
@testable import HomeGardenStudio

nonisolated final class DropImportTests: XCTestCase {
    func testDropLimitsAndURLParsing() throws {
        try DropImport.validateCount(8)
        XCTAssertThrowsError(try DropImport.validateCount(0))
        XCTAssertThrowsError(try DropImport.validateCount(9))
        XCTAssertEqual(try DropImport.parseURL(" https://example.com/garden\n").host, "example.com")
        XCTAssertEqual(try DropImport.parseURL("file:///tmp/synthetic.png").pathExtension, "png")
        for value in ["http://example.com", "https://user:secret@example.com", "file:///tmp/test.hgsplan", "file:///tmp/test.json", "https://example.com/\0hidden", "https://example.com/" + String(repeating: "x", count: 2000)] {
            XCTAssertThrowsError(try DropImport.parseURL(value), value)
        }
    }
    @MainActor func testDropFilePreservesOriginalAndRejectsSpoofedPDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("%PDF-1.4\n% synthetic exact-byte import fixture\n%%EOF\n".utf8)
        let url = directory.appendingPathComponent("Synthetic.pdf")
        try bytes.write(to: url)
        let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let prepared = try await DropImport.prepare(provider)
        XCTAssertEqual(prepared.bytes, bytes)
        XCTAssertEqual(prepared.source.originalFilename, "Synthetic.pdf")
        XCTAssertThrowsError(try ImportService.prepare(Data("not a PDF".utf8), filename: "spoof.pdf", type: .pdf))
        let store = try PlanStore(document: PlanDocument())
        let png = try await LayoutImageExport.png(store: store, includeBackdrop: false)
        let imageURL = directory.appendingPathComponent("Synthetic.png")
        try png.write(to: imageURL)
        let imageProvider = NSItemProvider(item: imageURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let image = try await DropImport.prepare(imageProvider)
        XCTAssertEqual(image.bytes, png)
        XCTAssertEqual(image.source.kind, "photo")
        XCTAssertEqual(image.source.pixelWidth, 1024)
    }
}

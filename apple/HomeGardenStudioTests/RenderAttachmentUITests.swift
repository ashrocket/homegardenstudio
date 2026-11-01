import XCTest
import CryptoKit
import ImageIO
@testable import HomeGardenStudio

nonisolated final class RenderAttachmentUITests: XCTestCase {
    @MainActor func testLayoutPNGAndRenderAttachmentRoundTrip() async throws {
        let doc = try PlanDocument(project: SamplePlan.make())
        let store = try PlanStore(document: doc)
        let png = try await LayoutImageExport.png(store: store, includeBackdrop: false)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let record = RenderAttachmentRecord(id: UUID(), projectID: doc.projectID, filename: sha + ".png", title: "Synthetic concept fixture", provider: "synthetic", inputDigest: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 1))
        try doc.attachRender(png, record: record)
        let read = try PlanDocument.read(PlanDocument.package(doc.snapshot(contentType: .gardenPlan)))
        XCTAssertEqual(read.projectID, doc.projectID)
        XCTAssertEqual(read.renderRecords.first?.id, record.id)
        XCTAssertEqual(read.renders[record.filename], png)
        var corrupt = read
        corrupt.renders[record.filename] = Data([1, 2, 3])
        XCTAssertThrowsError(try PlanDocument.read(PlanDocument.package(corrupt)))
    }
    @MainActor func testRenderCannotAttachToDifferentProject() async throws {
        let doc = PlanDocument()
        let store = try PlanStore(document: doc)
        let png = try await LayoutImageExport.png(store: store, includeBackdrop: false)
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let record = RenderAttachmentRecord(id: UUID(), projectID: UUID(), filename: sha + ".png", title: "Synthetic", provider: "synthetic", inputDigest: String(repeating: "0", count: 64), createdAt: Date())
        XCTAssertThrowsError(try doc.attachRender(png, record: record))
        XCTAssertTrue(doc.renderRecords.isEmpty)
        XCTAssertTrue(try doc.snapshot(contentType: .gardenPlan).renders.isEmpty)
    }
    func testSponsorshipRejectsUnsupportedInventory() throws {
        let json = #"{"offer_id":"synthetic","sponsor_name":"Synthetic test fixture","category":"unrestricted_ad_network","paid_for_by":"Synthetic fixture","disclosure":"Unit test only","report_url":"https://example.com/report","why_shown":"Synthetic fixture","windows":[{"minutes":30,"credit_cap_micros":1000000}]}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let offer = try decoder.decode(SponsorOffer.self, from: Data(json.utf8))
        XCTAssertThrowsError(try offer.validate())
    }
}

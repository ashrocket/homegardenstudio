import XCTest
import SwiftUI
import CryptoKit
@testable import HomeGardenStudio

nonisolated final class NativeTests:XCTestCase {
    @MainActor func testEngineSnapshotUndoRedoAndError() throws {
        let engine = HgsEngine(name:"Synthetic test")
        let response = try engine.command(EngineCommand("add_item",["kind":.string("pond"),"x":.number(2),"y":.number(3)])).get()
        let project = try engine.query(EngineQuery("snapshot"),as:Project.self).get()
        XCTAssertEqual(project.items.count,1); XCTAssertEqual(project.items[0].id,response.created[0])
        _ = try engine.command(EngineCommand("undo")).get()
        XCTAssertEqual(try engine.query(EngineQuery("snapshot"),as:Project.self).get().items.count,0)
        _ = try engine.command(EngineCommand("redo")).get()
        XCTAssertEqual(try engine.query(EngineQuery("snapshot"),as:Project.self).get().items.count,1)
        if case .failure(let error) = engine.command(EngineCommand("remove_items",["ids":.strings(["missing"])])) { XCTAssertEqual(error.code,"NOT_FOUND") } else { XCTFail("Missing ID must return an error") }
        for index in 0..<1000 { _ = try engine.command(EngineCommand("set_project_meta",["name":.string("Synthetic \(index)")])).get() }
    }
    @MainActor func testDocumentPackageRoundTripPreservesOriginals() throws {
        let data = try SamplePlan.make()
        let bytes = Data([0,255,13,10,42,0,77])
        let filename = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".bin"
        let doc = try PlanDocument(project:data,originals:[filename:bytes])
        let snapshot = try doc.snapshot(contentType:.gardenPlan)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".hgsplan",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        try PlanDocument.package(snapshot).write(to:folder,options:.atomic,originalContentsURL:nil)
        let read = try PlanDocument.read(FileWrapper(url:folder))
        XCTAssertEqual(read.project,snapshot.project)
        XCTAssertEqual(read.originals[filename],bytes)
        XCTAssertEqual(try HgsEngine(json:read.project).query(EngineQuery("snapshot"),as:Project.self).get().items.count,17)
    }
    @MainActor func testUnitParsingAndFormatting() throws {
        XCTAssertEqual(try XCTUnwrap(LengthFormatter.parse("7 ft 3 in",units:"imperial")),2.2098,accuracy:0.00001)
        XCTAssertEqual(try XCTUnwrap(LengthFormatter.parse("7'3\"",units:"metric")),2.2098,accuracy:0.00001)
        XCTAssertEqual(LengthFormatter.parse("2.2 m",units:"imperial"),2.2)
        XCTAssertEqual(LengthFormatter.format(2.2098,units:"imperial"),"7 ft 3 in")
        XCTAssertEqual(LengthFormatter.format(2.2,units:"metric"),"2.20 m")
        XCTAssertNil(LengthFormatter.parse("nan",units:"metric"))
        XCTAssertNil(LengthFormatter.parse("7 m 3 in",units:"metric"))
    }
    @MainActor func testFreePlanBlocksOnlyNewAdd() throws {
        let store = try PlanStore(document:PlanDocument())
        for _ in 0..<12 { XCTAssertTrue(store.perform(EngineCommand("add_item",["kind":.string("plant"),"x":.number(1),"y":.number(1)]),undoManager:nil)) }
        XCTAssertFalse(store.perform(EngineCommand("add_item",["kind":.string("plant"),"x":.number(1),"y":.number(1)]),undoManager:nil))
        XCTAssertEqual(store.project.items.count,12)
        XCTAssertTrue(store.perform(EngineCommand("update_item",["id":.string(store.project.items[0].id),"patch":.object(["name":.string("Edited")])]),undoManager:nil))
        let reopened = try PlanStore(document:PlanDocument(project:SamplePlan.make()))
        XCTAssertEqual(reopened.project.items.count,17)
        XCTAssertNoThrow(try reopened.engine.snapshot())
        let unlocked = try PlanStore(document:PlanDocument(),entitlements:Unlocked())
        for _ in 0..<13 { XCTAssertTrue(unlocked.perform(EngineCommand("add_item",["kind":.string("plant"),"x":.number(1),"y":.number(1)]),undoManager:nil)) }
        XCTAssertEqual(unlocked.project.items.count,13)
    }
    @MainActor func testNativeUndoRedo() throws {
        let store = try PlanStore(document:PlanDocument())
        let undo = UndoManager(); undo.groupsByEvent = false
        undo.beginUndoGrouping(); store.add("tree",undoManager:undo); undo.endUndoGrouping()
        XCTAssertEqual(store.project.items.count,1)
        undo.undo(); XCTAssertEqual(store.project.items.count,0)
        undo.redo(); XCTAssertEqual(store.project.items.count,1)
    }
    @MainActor func testUndoAcrossReplacementRetainsEarlierHistory() throws {
        let store = try PlanStore(document:PlanDocument())
        let undo = UndoManager(); undo.groupsByEvent = false
        undo.beginUndoGrouping(); store.add("tree",undoManager:undo); undo.endUndoGrouping()
        undo.beginUndoGrouping(); try store.replace(with:SamplePlan.make(),undoManager:undo); undo.endUndoGrouping()
        XCTAssertEqual(store.project.items.count,17)
        undo.undo(); XCTAssertEqual(store.project.items.count,1)
        undo.undo(); XCTAssertEqual(store.project.items.count,0)
        undo.redo(); XCTAssertEqual(store.project.items.count,1)
        undo.redo(); XCTAssertEqual(store.project.items.count,17)
    }
    @MainActor func testSourceEncodingMatchesContract() throws {
        let source = Source(id:"src-0123456789abcdef",kind:"url",title:"Synthetic",originalFilename:"source.html",sha256:String(repeating:"0",count:64),byteCount:4,mediaType:"text/html",url:"https://example.com",pixelWidth:nil,pixelHeight:nil,registration:nil,note:"Synthetic fixture")
        let value = try JSONValue.encode(source)
        guard case .object(let fields) = value else { return XCTFail("Expected source object") }
        XCTAssertEqual(fields["byte_count"],.number(4))
        XCTAssertEqual(fields["original_filename"],.string("source.html"))
        XCTAssertNil(fields["byteCount"])
    }
    @MainActor func testRejectedSourceImportPreservesProjectAndAttachments() throws {
        let store = try PlanStore(document: PlanDocument())
        let before = try store.document.snapshot(contentType: .gardenPlan)
        var prepared = syntheticImport(Data([1, 2, 3]))
        prepared.source.url = "https://example.com/" + String(repeating: "x", count: 2100)
        let undo = UndoManager()
        XCTAssertThrowsError(try store.importPrepared(prepared, undoManager: undo))
        let after = try store.document.snapshot(contentType: .gardenPlan)
        XCTAssertEqual(after.project, before.project)
        XCTAssertEqual(after.originals, before.originals)
        XCTAssertTrue(store.project.sources.isEmpty)
        XCTAssertFalse(undo.canUndo)
    }
    @MainActor func testCombinedRenderOriginalBudgetRejectsBeforeMutation() throws {
        let initial = try HgsEngine(name: "Synthetic").snapshot()
        let existing = syntheticImport(Data(repeating: 1, count: 40))
        let doc = try PlanDocument(project: initial, originals: [existing.storageName: existing.bytes], renders: ["render.bin": Data(repeating: 2, count: 200)], attachmentLimit: 256)
        XCTAssertNoThrow(try PlanDocument.read(PlanDocument.package(doc.snapshot(contentType: .gardenPlan))))
        let store = try PlanStore(document: doc)
        let before = try doc.snapshot(contentType: .gardenPlan)
        XCTAssertThrowsError(try store.importPrepared(syntheticImport(Data(repeating: 3, count: 30)), undoManager: nil))
        let after = try doc.snapshot(contentType: .gardenPlan)
        XCTAssertEqual(after.project, before.project)
        XCTAssertEqual(after.originals, before.originals)
        XCTAssertEqual(after.renders, before.renders)
        XCTAssertTrue(store.project.sources.isEmpty)
        XCTAssertFalse(store.history.canUndo)
    }
    @MainActor func testAcceptedImportCommitsMatchingMetadataAndBytes() throws {
        let doc = PlanDocument()
        let store = try PlanStore(document: doc)
        let prepared = syntheticImport(Data([1, 2, 3]))
        try store.importPrepared(prepared, undoManager: nil)
        let read = try PlanDocument.read(PlanDocument.package(doc.snapshot(contentType: .gardenPlan)))
        XCTAssertEqual(read.originals[prepared.storageName], prepared.bytes)
        XCTAssertTrue(read.warnings.isEmpty)
        XCTAssertEqual(store.project.sources.map(\.id), [prepared.source.id])
    }
    nonisolated private func syntheticImport(_ bytes: Data) -> PreparedImport {
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let source = Source(id: "src-" + sha.prefix(16), kind: "url", title: "Synthetic source", originalFilename: "source.html", sha256: sha, byteCount: bytes.count, mediaType: "text/html", url: "https://example.com", pixelWidth: nil, pixelHeight: nil, registration: nil, note: "Synthetic fixture")
        return PreparedImport(source: source, bytes: bytes, storageName: sha + ".html")
    }
    @MainActor func testNativeProjectIdentityPersistsAcrossPackageRoundTrip() throws {
        let doc = PlanDocument()
        let snapshot = try doc.snapshot(contentType: .gardenPlan)
        let reopened = try PlanDocument.read(PlanDocument.package(snapshot))
        XCTAssertEqual(reopened.projectID, doc.projectID)
        XCTAssertEqual(try PlanDocument.read(PlanDocument.package(reopened)).projectID, doc.projectID)
    }
    @MainActor func testInvalidUTF8AndNULRejectedBeforeFFI() throws {
        let valid = try HgsEngine(name: "Synthetic").snapshot()
        for invalid in [Data([0xff, 0xfe]), valid + Data([0]) + Data("trailing garbage".utf8)] {
            XCTAssertThrowsError(try HgsEngine(json: invalid))
            XCTAssertThrowsError(try EngineCodec.canonicalSnapshot(invalid))
        }
    }
    @MainActor func testUnexpectedPackageEntryRejected() throws {
        let wrapper = try PlanDocument.package(PlanDocument().snapshot(contentType: .gardenPlan))
        let extra = FileWrapper(regularFileWithContents: Data([1]))
        extra.preferredFilename = "unexpected.bin"
        wrapper.addFileWrapper(extra)
        XCTAssertThrowsError(try PlanDocument.read(wrapper))
    }
    @MainActor func testOversizedRenderRejected() throws {
        var snapshot = try PlanDocument().snapshot(contentType: .gardenPlan)
        snapshot.renders = ["synthetic.bin": Data(repeating: 0, count: 40 * 1024 * 1024 + 1)]
        XCTAssertThrowsError(try PlanDocument.read(PlanDocument.package(snapshot)))
    }
    @MainActor func testMissingOriginalSurfacesWarning() throws {
        let engine = HgsEngine(name:"Synthetic")
        let source = Source(id:"src-" + String(repeating:"0",count:16),kind:"url",title:"Missing source",originalFilename:"source.html",sha256:String(repeating:"0",count:64),byteCount:4,mediaType:"text/html",url:"https://example.com",pixelWidth:nil,pixelHeight:nil,registration:nil,note:"Synthetic fixture")
        _ = try engine.command(EngineCommand("add_source",["source":try JSONValue.encode(source)])).get()
        let doc = try PlanDocument(project:engine.snapshot())
        let snapshot = try PlanDocument.read(PlanDocument.package(doc.snapshot(contentType:.gardenPlan)))
        XCTAssertEqual(snapshot.warnings.count,1)
        XCTAssertTrue(snapshot.warnings[0].contains("metadata only"))
    }
    @MainActor func testCorruptOriginalRejected() throws {
        let doc = try PlanDocument(project:SamplePlan.make(),originals:["invalid.bin":Data([1,2,3])])
        XCTAssertThrowsError(try PlanDocument.read(PlanDocument.package(doc.snapshot(contentType:.gardenPlan))))
    }
    @MainActor func testURLTitleExtraction() {
        XCTAssertEqual(ImportService.extractTitle("<html><title>Fallback</title><meta property='og:title' content='Garden &amp; Pond'></html>"),"Garden & Pond")
        XCTAssertEqual(ImportService.extractTitle("<TITLE>  A garden  </TITLE>"),"A garden")
        XCTAssertNil(ImportService.extractTitle("<html>No title</html>"))
    }
    @MainActor func testScaleCalibrationDoesNotEstablishMeasurement() throws {
        let engine = HgsEngine(name:"Synthetic")
        let item = try engine.command(EngineCommand("add_item",["kind":.string("plant"),"x":.number(1),"y":.number(1)])).get().created[0]
        let result = engine.command(EngineCommand("mark_measured",["id":.string(item),"evidence":.string("registered_source:missing")]))
        if case .success = result { XCTFail("Photo evidence must not establish measurement") }
    }
}
private struct Unlocked:Entitlements { var isUnlocked:Bool { true } }

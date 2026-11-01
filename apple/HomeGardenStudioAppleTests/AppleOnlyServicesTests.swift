import XCTest
import ImageIO
@testable import HomeGardenStudioApple

nonisolated final class AppleOnlyServicesTests: XCTestCase {
    @MainActor func testPreparationAndRetryKeepLocalDevelopmentModeReady() async {
        let services = StudioServices()
        XCTAssertTrue(services.isUnlocked)
        XCTAssertFalse(services.isPreparing)
        await services.prepare()
        await services.prepare()
        await services.retrySetup()
        XCTAssertTrue(services.isPrepared)
        XCTAssertTrue(services.isUnlocked)
        XCTAssertFalse(services.isPreparing)
        XCTAssertTrue(services.modeDescription.contains("development edition"))
        XCTAssertTrue(services.networkDescription.contains("URL imports"))
        XCTAssertTrue(services.networkDescription.contains("Private Cloud Compute"))
        // This module excludes account, Keychain, gateway, billing and remote render implementations.
        // Preparation has no configuration arguments or service dependency to initialize.
    }
    @MainActor func testLocalEditingBeyondTwelveFeaturesRetainsUndoAndPortableExport() throws {
        let services = StudioServices(), document = PlanDocument()
        let store = try PlanStore(document: document, entitlements: services)
        for index in 0..<15 { store.add("tree", at: CGPoint(x: Double(index), y: 1), undoManager: nil) }
        XCTAssertEqual(store.project.items.count, 15)
        XCTAssertFalse(store.showTrialLimit)
        store.travel("undo", undoManager: nil)
        XCTAssertEqual(store.project.items.count, 14)
        store.travel("redo", undoManager: nil)
        XCTAssertEqual(store.project.items.count, 15)
        let reopened = try PlanDocument.read(PlanDocument.package(document.snapshot(contentType: .gardenPlan)))
        let project = try EngineCodec.decoder().decode(Project.self, from: reopened.project)
        XCTAssertEqual(project.items.count, 15)
        XCTAssertEqual(reopened.projectID, document.projectID)
    }
    @MainActor func testExistingSampleStaysEditableWithoutAccountSetup() throws {
        let document = try PlanDocument(project: SamplePlan.make())
        let store = try PlanStore(document: document, entitlements: StudioServices())
        let originalCount = store.project.items.count
        XCTAssertGreaterThan(originalCount, 12)
        let item = try XCTUnwrap(store.project.items.first)
        store.update(item, ["name": .string("Synthetic local edit")], undoManager: nil)
        store.add("tree", undoManager: nil)
        XCTAssertEqual(store.project.items.count, originalCount + 1)
        XCTAssertEqual(store.project.items.first(where: { $0.id == item.id })?.name, "Synthetic local edit")
        XCTAssertFalse(store.showTrialLimit)
        XCTAssertFalse(try store.engine.snapshot().isEmpty)
    }
    @MainActor func testLocalLayoutPNGDoesNotIncludeImportedBackdropWithoutOptIn() async throws {
        let document = PlanDocument(), services = StudioServices()
        let store = try PlanStore(document: document, entitlements: services)
        let baseline = try await LayoutImageExport.png(store: store, includeBackdrop: false)
        let original = try ImportService.prepare(baseline, filename: "Synthetic-layout.png", type: .png)
        try store.importPrepared(original, undoManager: nil)
        XCTAssertTrue(store.perform(EngineCommand("set_backdrop", ["source_id": .string(original.source.id), "x": .number(0), "y": .number(0), "rotation": .number(0), "opacity": .number(0.6)]), undoManager: nil))
        let exported = try await LayoutImageExport.png(store: store, includeBackdrop: false)
        XCTAssertEqual(exported, baseline)
        XCTAssertEqual(document.original(sha: try XCTUnwrap(original.source.sha256)), baseline)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(exported as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
    }
}

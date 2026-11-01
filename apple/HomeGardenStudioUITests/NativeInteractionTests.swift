import XCTest

/// Real user interactions against an isolated simulator. No model imports, injected documents,
/// launch-time backdoors, account setup, permission bypasses or paid cloud operations.
nonisolated final class NativeInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func test01CreateFeatureEditDimensionAndUndo() throws {
        let app = launch()
        defer { capture(app, name: "feature-flow-final") }
        try createDocument(in: app)
        try tap(app.buttons["workspace.library"], in: app)
        let addPlant = app.buttons["library.add.plant"]
        try reveal(addPlant, in: app)
        try tap(addPlant, in: app)
        try tap(app.buttons["Done"].firstMatch, in: app)
        try tap(app.buttons["workspace.inspector"], in: app)
        let width = app.textFields["field.Width"]
        try reveal(width, in: app)
        let original = try stringValue(width, in: app)
        XCTAssertFalse(original.isEmpty)
        try replaceText(width, with: "2 m", in: app)
        XCTAssertNotEqual(try stringValue(width, in: app), original)
        capture(app, name: "feature-dimension-edited")
        try tap(app.buttons["inspector.done"], in: app)
        let undo = app.buttons["workspace.undo"]
        try require(undo, in: app)
        XCTAssertTrue(undo.isEnabled, "A committed dimension change must be undoable.")
        undo.tap()
        try tap(app.buttons["workspace.inspector"], in: app)
        try reveal(width, in: app)
        let restored = NSPredicate(format: "value == %@", original)
        XCTAssertTrue(wait(for: restored, on: width), "Undo must restore the displayed dimension.")
        capture(app, name: "feature-dimension-restored")
        try tap(app.buttons["inspector.done"], in: app)
        try require(element("preview.plan", in: app), in: app)
    }

    @MainActor func test02SyntheticPlanIsometricAndThreeDViews() throws {
        let app = launch()
        defer { capture(app, name: "preview-flow-final") }
        try createDocument(in: app)
        try tap(app.buttons["workspace.actions"], in: app)
        try tap(app.buttons["Open sample plan"].firstMatch, in: app)
        // A confirmation is shown only if an existing nonempty document was deliberately reused.
        if app.buttons["Open sample plan"].firstMatch.waitForExistence(timeout: 1) {
            try tap(app.buttons["Open sample plan"].firstMatch, in: app)
        }
        try require(element("preview.plan", in: app), in: app)
        capture(app, name: "synthetic-plan")
        let picker = app.segmentedControls["workspace.viewPicker"]
        try require(picker, in: app)
        try tap(picker.buttons["Isometric"], in: app)
        try require(element("preview.isometric", in: app), in: app)
        capture(app, name: "synthetic-isometric")
        try tap(app.buttons["Rotate right"], in: app)
        capture(app, name: "synthetic-isometric-rotated")
        try tap(picker.buttons["3D"], in: app)
        try require(element("preview.threeD", in: app), in: app, timeout: 30)
        XCTAssertFalse(app.staticTexts["Building local 3D preview"].exists)
        capture(app, name: "synthetic-three-dimensional")
        try tap(picker.buttons["Plan"], in: app)
        try require(element("preview.plan", in: app), in: app)
        capture(app, name: "synthetic-plan-returned")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func createDocument(in app: XCUIApplication) throws {
        if app.buttons["workspace.library"].waitForExistence(timeout: 2) {
            let back = ["Back", "Documents", "Browse"].map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
            guard let back else { try fail("The document browser back control is unavailable.", app: app); return }
            back.tap()
        }
        let labels = ["Create Document", "New Document", "Create new document"]
        var create = labels.map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
        if create == nil {
            let add = app.buttons["Add"].firstMatch
            if add.waitForExistence(timeout: 5), add.isHittable {
                add.tap()
                create = labels.map { app.buttons[$0].firstMatch }.first { $0.waitForExistence(timeout: 2) && $0.isHittable }
            }
        }
        guard let create else { try fail("The standard document browser did not expose Create Document.", app: app); return }
        create.tap()
        if app.buttons["Create"].firstMatch.waitForExistence(timeout: 2), !app.buttons["workspace.library"].exists {
            app.buttons["Create"].firstMatch.tap()
        }
        try require(app.buttons["workspace.library"], in: app, timeout: 25)
        try require(element("preview.plan", in: app), in: app)
        capture(app, name: "new-document")
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication) throws {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        try require(target, in: app)
        guard target.isHittable else { try fail("The requested control remained outside the visible form.", app: app); return }
    }

    @MainActor private func replaceText(_ field: XCUIElement, with replacement: String, in app: XCUIApplication) throws {
        let current = try stringValue(field, in: app)
        field.tap()
        // Tap the visible end of this short dimension value, then use the real keyboard.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        guard wait(for: NSPredicate(format: "value == ''"), on: field) else {
            try fail("The field could not be cleared through the keyboard.", app: app); return
        }
        field.typeText(replacement + "\n")
    }

    @MainActor private func stringValue(_ field: XCUIElement, in app: XCUIApplication) throws -> String {
        try require(field, in: app)
        guard let value = field.value as? String else { try fail("Expected an editable text value.", app: app); return "" }
        return value
    }

    @MainActor private func tap(_ target: XCUIElement, in app: XCUIApplication) throws {
        try require(target, in: app)
        guard target.isHittable else { try fail("The requested control is not hittable.", app: app); return }
        target.tap()
    }

    @MainActor private func require(_ target: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) throws {
        guard target.waitForExistence(timeout: timeout) else { try fail("A required UI element did not appear.", app: app); return }
    }

    @MainActor private func wait(for predicate: NSPredicate, on target: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)], timeout: 5) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor private func fail(_ message: String, app: XCUIApplication) throws {
        capture(app, name: "failure-screen")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "failure-accessibility-tree"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(message)
        throw UIInteractionFailure.missingControl
    }
}

private nonisolated enum UIInteractionFailure: Error { case missingControl }

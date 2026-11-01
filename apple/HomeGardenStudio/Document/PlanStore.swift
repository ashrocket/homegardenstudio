import SwiftUI
import Observation

@MainActor protocol Entitlements { var isUnlocked: Bool { get } }
struct FreePlanEntitlements: Entitlements { var isUnlocked: Bool { false } }

@Observable @MainActor final class PlanStore {
    let document: PlanDocument
    private(set) var engine: HgsEngine
    private(set) var project: Project
    private(set) var catalog: [CatalogEntry] = []
    private(set) var issues: [Issue] = []
    private(set) var history = HistoryState.empty
    private(set) var revision = 0
    var selection: Set<String> = []
    var error: String?
    var showTrialLimit = false
    var snapTransforms = false
    var fitRequest = 0
    var canvasCenter = CGPoint(x: 12, y: 9)
    var drawingBoundary = false
    var boundaryPoints: [[Double]] = []
    let entitlements: any Entitlements
    init(document: PlanDocument, entitlements: any Entitlements = FreePlanEntitlements()) throws {
        self.document = document; self.entitlements = entitlements
        let openedEngine = try HgsEngine(json: document.snapshot(contentType: .gardenPlan).project)
        engine = openedEngine
        project = try openedEngine.query(EngineQuery("snapshot"), as: Project.self).get()
        try refresh()
        error = try document.snapshot(contentType: .gardenPlan).warnings.first
    }
    @discardableResult func perform(_ command: EngineCommand, undoManager: UndoManager?) -> Bool {
        let op = command.fields["op"]
        var added = 0
        if op == .string("add_item") { added = 1 }
        if op == .string("duplicate_items"), case .array(let ids) = command.fields["ids"] { added = ids.count }
        if added > 0 && !entitlements.isUnlocked && project.items.count + added > 12 { showTrialLimit = true; return false }
        switch engine.command(command) {
        case .failure(let failure): error = failure.localizedDescription; return false
        case .success(let response):
            do {
                try refresh()
                if !response.created.isEmpty { selection = Set(response.created) }
                if let undoManager {
                    undoManager.registerUndo(withTarget: self) { target in target.travel("undo", undoManager: undoManager) }
                    undoManager.setActionName(response.history.undoLabel ?? "Edit plan")
                }
                return true
            } catch { self.error = error.localizedDescription; return false }
        }
    }
    func travel(_ direction: String, undoManager: UndoManager?) {
        let label = direction == "undo" ? history.undoLabel : history.redoLabel
        switch engine.command(EngineCommand(direction)) {
        case .failure(let failure): error = failure.localizedDescription
        case .success:
            do { try refresh() } catch { self.error = error.localizedDescription }
            undoManager?.registerUndo(withTarget: self) { target in target.travel(direction == "undo" ? "redo" : "undo", undoManager: undoManager) }
            undoManager?.setActionName(label ?? "Edit plan")
        }
    }
    private func refresh(persist: Bool = true) throws {
        project = try engine.query(EngineQuery("snapshot"), as: Project.self).get()
        catalog = try engine.query(EngineQuery("catalog"), as: [CatalogEntry].self).get()
        issues = try engine.query(EngineQuery("validate"), as: [Issue].self).get()
        history = try engine.query(EngineQuery("history"), as: HistoryState.self).get()
        selection.formIntersection(Set(project.items.map(\.id)))
        revision += 1
        if persist { document.update(project: try engine.snapshot()) }
    }
    func add(_ kind: String, at point: CGPoint? = nil, undoManager: UndoManager?) {
        let p = point ?? canvasCenter
        perform(EngineCommand("add_item", ["kind": .string(kind), "x": .number(p.x), "y": .number(p.y)]), undoManager: undoManager)
    }
    func selectedItem() -> Item? { project.items.first { selection.contains($0.id) } }
    func duplicate(undoManager: UndoManager?) { perform(EngineCommand("duplicate_items", ["ids": .strings(Array(selection)), "dx": .number(0.5), "dy": .number(0.5)]), undoManager: undoManager) }
    func remove(undoManager: UndoManager?) { perform(EngineCommand("remove_items", ["ids": .strings(Array(selection))]), undoManager: undoManager) }
    func update(_ item: Item, _ patch: [String: JSONValue], undoManager: UndoManager?) { perform(EngineCommand("update_item", ["id": .string(item.id), "patch": .object(patch)]), undoManager: undoManager) }
    func finishBoundary(undoManager: UndoManager?) {
        guard boundaryPoints.count >= 3 else { error = "Add at least three boundary points."; return }
        if perform(EngineCommand("set_boundary", ["outline": .array(boundaryPoints.map { .point($0[0], $0[1]) }), "certainty": .string("estimated")]), undoManager: undoManager) { drawingBoundary = false; boundaryPoints = [] }
    }
    func importPrepared(_ prepared: PreparedImport, undoManager: UndoManager?) throws {
        guard !project.sources.contains(where: { $0.id == prepared.source.id }) else {
            throw EngineError(code: "DUPLICATE_SOURCE", message: "This source is already in the plan.")
        }
        try document.checkOriginalCapacity(prepared.bytes, named: prepared.storageName)
        let command = EngineCommand("add_source", ["source": try JSONValue.encode(prepared.source)])
        let response = try engine.command(command).get()
        do {
            let snapshot = try engine.snapshot()
            try refresh(persist: false)
            try document.commitOriginal(prepared.bytes, named: prepared.storageName, project: snapshot)
        } catch {
            _ = engine.command(EngineCommand("undo"))
            try? refresh(persist: false)
            throw error
        }
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in target.travel("undo", undoManager: undoManager) }
            undoManager.setActionName(response.history.undoLabel ?? "Import source")
        }
    }
    /// Loading any existing plan, including a larger synthetic sample, is never gated by the new-add trial.
    func replace(with data: Data, undoManager: UndoManager?) throws {
        let next = try HgsEngine(json: data)
        try install(next, undoManager: undoManager)
    }
    private func install(_ next: HgsEngine, undoManager: UndoManager?) throws {
        let previous = engine
        engine = next
        undoManager?.registerUndo(withTarget: self) { target in
            do { try target.install(previous, undoManager: undoManager) } catch { target.error = error.localizedDescription }
        }
        undoManager?.setActionName("Load plan")
        selection = []; try refresh(); fitRequest += 1
    }
    func openSample(undoManager: UndoManager?) {
        do { try replace(with: SamplePlan.make(), undoManager: undoManager) }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor enum SamplePlan {
    static func make() throws -> Data {
        let e = HgsEngine(name: "Sample garden (synthetic)")
        func command(_ op: String, _ fields: [String: JSONValue]) throws { _ = try e.command(EngineCommand(op, fields)).get() }
        try command("set_boundary", ["outline": .array([.point(0,0), .point(24,0), .point(24,18), .point(0,18)]), "certainty": .string("estimated")])
        try command("add_structure", ["name": .string("House — synthetic"), "outline": .array([.point(1,1), .point(10,1), .point(10,6), .point(1,6)]), "height": .number(5), "certainty": .string("estimated")])
        let features: [(String, Double, Double)] = [("sauna",20,3),("pergola",13,4),("fire_pit",18,13),("pond",6,13),("tool_shed",22,7),("bin_screen",2,8),("patio",11,9),("path",7,9),("tree",2,15),("tree",10,16),("tree",22,16),("plant",3,11),("plant",4,11),("plant",5,11),("plant",6,11),("plant",7,11),("plant",8,11)]
        for (kind,x,y) in features { try command("add_item", ["kind": .string(kind), "x": .number(x), "y": .number(y)]) }
        return try e.snapshot()
    }
}

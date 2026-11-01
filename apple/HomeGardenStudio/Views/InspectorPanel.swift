import SwiftUI

struct InspectorPanel: View {
    @Bindable var store: PlanStore
    @Environment(\.undoManager) private var undoManager
    var body: some View {
        Form {
            if let item = store.selectedItem() { ItemEditor(store:store,item:item).id(item.id) }
            else {
                Section("Plan") {
                    CommitField("Name",value:store.project.name) { store.perform(EngineCommand("set_project_meta",["name":.string($0)]),undoManager:undoManager) }
                    Picker("Display units",selection:Binding(get:{store.project.units},set:{ store.perform(EngineCommand("set_project_meta",["units":.string($0)]),undoManager:undoManager) })) { Text("Feet and inches").tag("imperial"); Text("Metres").tag("metric") }
                    if store.drawingBoundary {
                        Button("Done drawing boundary") { store.finishBoundary(undoManager:undoManager) }
                        Button("Cancel boundary",role:.cancel) { store.drawingBoundary = false; store.boundaryPoints = [] }
                    } else { Button("Draw boundary") { store.boundaryPoints = []; store.drawingBoundary = true } }
                    Text("Drawn boundaries are estimated. This plan is not a survey.").font(.caption).foregroundStyle(.secondary)
                    StructureEditor(store:store)
                }
            }
            Section("Features · \(store.project.items.count)") {
                if store.project.items.isEmpty { Text("Add a feature from the library, or open the synthetic sample.").foregroundStyle(.secondary) }
                ForEach(store.project.items) { item in
                    Button { store.selection = [item.id] } label: { HStack { Text(item.name); Spacer(); if store.selection.contains(item.id) { Image(systemName:"checkmark") } } }
                }
                if !store.selection.isEmpty { Button("Deselect all") { store.selection = [] } }
            }
            Section("Layout checks") {
                if store.issues.isEmpty { Text("No layout issues found. Not a survey or safety certification.").font(.caption) }
                ForEach(Array(store.issues.enumerated()),id:\.offset) { _,issue in
                    Button { if let id = issue.itemId { store.selection = [id] } } label: { Label(issue.message,systemImage:issue.severity == "warning" ? "exclamationmark.triangle" : "info.circle").font(.caption).multilineTextAlignment(.leading) }
                }
            }
            Section { Text("Free plan: add up to 12 features per plan. Existing work stays editable and exportable.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).navigationTitle("Inspector")
    }
}
private struct ItemEditor: View {
    @Bindable var store: PlanStore
    let item: Item
    @Environment(\.undoManager) private var undoManager
    @State private var measurementField = "position"
    @State private var evidenceNote = ""
    @State private var showMeasured = false
    var body: some View {
        Section("Feature") {
            CommitField("Name",value:item.name) { edit(["name":.string($0)]) }
            Toggle("Locked",isOn:Binding(get:{item.locked},set:{edit(["locked":.bool($0)])}))
            Text("Position: \(certainty(item.positionCertainty))").font(.caption)
            Text("Dimensions: \(certainty(item.sizeCertainty))").font(.caption)
            if let evidence = item.positionEvidence { Text(evidence.note).font(.caption).foregroundStyle(.secondary) }
        }
        Section("Position and dimensions") {
            length("X",key:"x",value:item.x); length("Y",key:"y",value:item.y)
            length("Width",key:"width",value:item.width); length("Depth",key:"depth",value:item.depth); length("Height",key:"height",value:item.height)
            CommitField("Rotation (degrees)",value:String(format:"%.1f",item.rotation)) { text in
                guard let value = Double(text), value.isFinite else { store.error = "Enter a rotation in degrees."; return }; edit(["rotation":.number(value)])
            }.disabled(item.locked)
            Toggle("Keep proportions / snap rotation",isOn:$store.snapTransforms)
        }
        Section("Details") {
            if item.kind == "plant" || item.kind == "tree" { CommitField("Species",value:stringParam("species")) { params("species",.string($0)) } }
            if item.kind == "fire_pit" { parameterLength("Pit diameter",key:"pit_diameter",fallback:1.07); parameterLength("Clearance",key:"clearance",fallback:3.05) }
            if item.kind == "pond" { parameterLength("Water depth",key:"water_depth",fallback:0.6) }
            if item.kind == "bin_screen" { parameterLength("Wall thickness",key:"wall_thickness",fallback:0.05); Text("L-shaped screen, open at the front and right, with no roof.").font(.caption) }
            CommitField("Notes",value:item.notes) { edit(["notes":.string($0)]) }
            if let product = item.product, let url = URL(string:product.url), url.scheme == "https" { Link(product.title,destination:url); Text(product.listedDimensions).font(.caption) }
            Button("Record field measurement…") { showMeasured = true }
            Text("Photo scale calibration cannot establish measured positions. Record a measurement only after checking it on site.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Source references") {
            if store.project.sources.isEmpty { Text("No sources imported.").foregroundStyle(.secondary) }
            ForEach(store.project.sources) { source in
                Toggle(source.title,isOn:Binding(get:{item.sourceIds.contains(source.id)},set:{ selected in
                    var ids = item.sourceIds; if selected { ids.append(source.id) } else { ids.removeAll { $0 == source.id } }; edit(["source_ids":.strings(ids)])
                }))
            }
        }
        Section {
            Button("Duplicate") { store.duplicate(undoManager:undoManager) }.keyboardShortcut("d",modifiers:.command)
            Button("Delete feature",role:.destructive) { store.remove(undoManager:undoManager) }
        }
        .sheet(isPresented:$showMeasured) {
            NavigationStack {
                Form {
                    Text("This records your assertion that the current values match a measurement taken on site. A photo calibration is not enough.")
                    Picker("Measured values",selection:$measurementField) { Text("Position and rotation").tag("position"); Text("Dimensions").tag("size") }
                    TextField("Measurement method / reference",text:$evidenceNote,axis:.vertical)
                    Button("Record measured values") {
                        if store.perform(EngineCommand("mark_measured",["id":.string(item.id),"evidence":.string("field_measurement"),"field":.string(measurementField),"note":.string(evidenceNote)]),undoManager:undoManager) { showMeasured = false }
                    }.disabled(evidenceNote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.navigationTitle("Field measurement").toolbar { Button("Cancel") { showMeasured = false } }
            }.frame(minWidth:300,minHeight:320)
        }
    }
    private func certainty(_ value:String) -> String { switch value { case "measured":"Measured on site"; case "product_listing":"From product listing"; case "unregistered_photo":"From unregistered photo"; default:"Estimated" } }
    private func edit(_ patch:[String:JSONValue]) { store.update(item,patch,undoManager:undoManager) }
    private func length(_ label:String,key:String,value:Double) -> some View {
        CommitField(label,value:LengthFormatter.format(value,units:store.project.units)) { text in
            guard let v = LengthFormatter.parse(text,units:store.project.units) else { store.error = "Enter a length such as 7 ft 3 in or 2.2 m."; return }; edit([key:.number(v)])
        }.disabled(item.locked)
    }
    private func stringParam(_ key:String) -> String { if case .string(let value) = item.params[key] { return value }; return "" }
    private func params(_ key:String,_ value:JSONValue) { var p = item.params; p[key] = value; edit(["params":.object(p)]) }
    private func parameterLength(_ label:String,key:String,fallback:Double) -> some View {
        let value:Double = { if case .number(let value) = item.params[key] { return value }; return fallback }()
        return CommitField(label,value:LengthFormatter.format(value,units:store.project.units)) { text in
            guard let v = LengthFormatter.parse(text,units:store.project.units) else { store.error = "Enter a valid length."; return }; params(key,.number(v))
        }.disabled(item.locked)
    }
}

struct CommitField: View {
    let label:String; let value:String; let commit:(String)->Void
    @State private var draft = ""
    @FocusState private var focused:Bool
    init(_ label:String,value:String,commit:@escaping(String)->Void) { self.label = label; self.value = value; self.commit = commit }
    var body:some View {
        TextField(label,text:$draft).focused($focused).onAppear { draft = value }.onChange(of:value) { _,value in if !focused { draft = value } }.onSubmit { focused = false }.onChange(of:focused) { was,now in if was && !now && draft != value { commit(draft) } }
    }
}
private struct StructureEditor:View {
    var store:PlanStore
    @Environment(\.undoManager) private var undoManager
    @State private var showing = false
    @State private var name = "House"
    @State private var width = "6 m"
    @State private var depth = "4 m"
    @State private var height = "3 m"
    var body:some View {
        Button("Add structure…") { showing = true }.sheet(isPresented:$showing) {
            NavigationStack {
                Form {
                    TextField("Name",text:$name); TextField("Width",text:$width); TextField("Depth",text:$depth); TextField("Height",text:$height)
                    Text("Placed at the canvas centre with estimated dimensions.").font(.caption)
                    Button("Add structure") {
                        guard let w = LengthFormatter.parse(width,units:store.project.units), let d = LengthFormatter.parse(depth,units:store.project.units), let h = LengthFormatter.parse(height,units:store.project.units), w > 0, d > 0 else { store.error = "Enter valid structure dimensions."; return }
                        let p = store.canvasCenter
                        let outline:[JSONValue] = [.point(p.x-w/2,p.y-d/2),.point(p.x+w/2,p.y-d/2),.point(p.x+w/2,p.y+d/2),.point(p.x-w/2,p.y+d/2)]
                        if store.perform(EngineCommand("add_structure",["name":.string(name),"outline":.array(outline),"height":.number(h),"certainty":.string("estimated")]),undoManager:undoManager) { showing = false }
                    }
                }.navigationTitle("Structure").toolbar { Button("Cancel") { showing = false } }
            }.frame(minWidth:300,minHeight:340)
        }
    }
}

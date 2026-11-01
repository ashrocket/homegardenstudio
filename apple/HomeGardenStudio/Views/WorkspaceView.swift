import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct DocumentWorkspace:View {
    let document:PlanDocument
    let fileURL:URL?
    @State private var store:PlanStore?
    @State private var error:String?
    var body:some View {
        Group {
            if let store { WorkspaceView(store:store,fileURL:fileURL) }
            else if let error { ContentUnavailableView("Could not open plan",systemImage:"exclamationmark.triangle",description:Text(error)) }
            else { ProgressView("Opening plan") }
        }.task {
            guard store == nil else { return }
            do { store = try PlanStore(document:document) } catch { self.error = error.localizedDescription }
        }
    }
}

struct WorkspaceView:View {
    @Bindable var store:PlanStore
    let fileURL:URL?
    @Environment(\.undoManager) private var undoManager
    @State private var mode = "Plan"
    @State private var library = false
    @State private var inspector = false
    @State private var sources = false
    @State private var importFiles = false
    @State private var importJSON = false
    @State private var exportJSON = false
    @State private var exportPackage = false
    @State private var exportedPackage: PackageExport?
    @State private var wideWorkspace = false
    @State private var exported = JSONPlanExport(data:Data())
    @State private var urlSheet = false
    @State private var urlText = ""
    @State private var importing = false
    @State private var photo:PhotosPickerItem?
    @State private var showSampleWarning = false
    @State private var showJSONWarning = false
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if library && geometry.size.width >= 850 {
                            LibraryPanel(store: store).frame(width: 300)
                            Divider()
                        }
                        workspace
                    }
                    .onAppear { wideWorkspace = geometry.size.width >= 850 }
                    .onChange(of: geometry.size.width) { _, width in wideWorkspace = width >= 850 }
                }
                HStack(spacing:12) {
                    Button { library.toggle() } label: { Label("Library",systemImage:"plus") }
                    Menu {
                        PhotosPicker(selection:$photo,matching:.images,preferredItemEncoding:.current,photoLibrary:.shared()) { Label("Photo library",systemImage:"photo") }
                        Button("Image or PDF…") { importFiles = true }
                        Button("Page URL…") { urlSheet = true }
                        Button("Sources and calibration…") { sources = true }
                    } label: { Label("Import",systemImage:"square.and.arrow.down") }
                    Spacer(minLength:0)
                    Button { inspector.toggle() } label: { Label("Inspector",systemImage:"sidebar.right") }
                }.buttonStyle(.bordered).padding(10).background(.bar)
            }.navigationTitle(store.project.name)
                .toolbar { workspaceToolbar }
                .inspector(isPresented:$inspector) { InspectorPanel(store:store).inspectorColumnWidth(min:280,ideal:330,max:450) }
                .sheet(isPresented:Binding(get:{library && !wideWorkspace},set:{library = $0})) { NavigationStack { LibraryPanel(store:store).toolbar { Button("Done") { library = false } } }.frame(minWidth:320,minHeight:450).presentationDetents([.medium,.large]).presentationBackgroundInteraction(.enabled(upThrough:.medium)) }
                .sheet(isPresented:$sources) { NavigationStack { SourcesPanel(store:store).toolbar { Button("Done") { sources = false } } }.frame(minWidth:320,minHeight:450) }
                .sheet(isPresented:$urlSheet) { urlImportSheet }
                .sheet(isPresented:$store.showTrialLimit) { trialSheet }
                .alert("Plan notice",isPresented:Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
                .confirmationDialog("Replace this plan with the synthetic sample?",isPresented:$showSampleWarning,titleVisibility:.visible) { Button("Open sample plan") { store.openSample(undoManager:undoManager) } } message: { Text("This replaces the current layout. You can undo the change; imported originals remain in the package.") }
                .confirmationDialog("Replace this plan from JSON?",isPresented:$showJSONWarning,titleVisibility:.visible) { Button("Choose JSON…") { importJSON = true } } message: { Text("JSON contains layout and source metadata only. To preserve photos and attachments, open an .hgsplan package instead. You can undo this replacement.") }
                .fileImporter(isPresented:$importFiles,allowedContentTypes:[.image,.pdf]) { result in
                    switch result { case .success(let url): runImport { try await Task.detached { try ImportService.file(url) }.value }; case .failure(let error): store.error = error.localizedDescription }
                }
                .fileImporter(isPresented:$importJSON,allowedContentTypes:[.json]) { result in importPlanJSON(result) }
                .fileExporter(isPresented:$exportPackage,document:exportedPackage,contentType:.gardenPlan,defaultFilename:store.project.name) { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
                .fileExporter(isPresented:$exportJSON,document:exported,contentType:.json,defaultFilename:store.project.name) { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
                .onChange(of:photo) { _,item in
                    guard let item else { return }
                    importing = true
                    Task {
                        defer { importing = false; photo = nil }
                        do {
                            guard let data = try await item.loadTransferable(type:Data.self) else { throw EngineError(code:"IMPORT_ERROR",message:"The selected photo could not be loaded.") }
                            let type = item.supportedContentTypes.first
                            let filename = "Photo." + (type?.preferredFilenameExtension ?? "image")
                            let prepared = try await Task.detached { try ImportService.prepare(data,filename:filename,type:type) }.value
                            try store.importPrepared(prepared,undoManager:undoManager)
                            sources = true
                        } catch { store.error = error.localizedDescription }
                    }
                }
                .overlay { if importing { ProgressView("Importing original…").padding().background(.background,in:RoundedRectangle(cornerRadius:12)) } }
                #if os(macOS)
                .windowToolbarFullScreenVisibility(.visible)
                .frame(minWidth:650,minHeight:480)
                #endif
        }
    }
    @ViewBuilder private var workspace:some View {
        switch mode { case "Isometric":IsometricView(store:store); case "3D":Scene3DView(store:store); default:PlanCanvasView(store:store) }
    }
    @ToolbarContentBuilder private var workspaceToolbar:some ToolbarContent {
        ToolbarItem(placement:.principal) {
            Picker("View",selection:$mode) { Text("Plan").tag("Plan"); Text("Isometric").tag("Isometric"); Text("3D").tag("3D") }.pickerStyle(.segmented).frame(maxWidth:280)
        }
        ToolbarItemGroup(placement:.primaryAction) {
            Button { undoManager?.undo() } label: { Label("Undo",systemImage:"arrow.uturn.backward") }.disabled(!(undoManager?.canUndo ?? false)).help(store.history.undoLabel ?? "Undo")
            Button { undoManager?.redo() } label: { Label("Redo",systemImage:"arrow.uturn.forward") }.disabled(!(undoManager?.canRedo ?? false)).help(store.history.redoLabel ?? "Redo")
            Menu {
                Button("Feature library",systemImage:"plus") { library = true }
                Button("Sources and calibration",systemImage:"ruler") { sources = true }
                Button("Inspector",systemImage:"sidebar.right") { inspector.toggle() }
                if store.drawingBoundary { Button("Done drawing boundary") { store.finishBoundary(undoManager:undoManager) } }
                Divider()
                Button("Export portable plan…") {
                    do { exportedPackage = PackageExport(try store.document.snapshot(contentType: .gardenPlan)); exportPackage = true } catch { store.error = error.localizedDescription }
                }
                Button("Export plan data (JSON)…") { do { exported = JSONPlanExport(data:try store.engine.snapshot()); exportJSON = true } catch { store.error = error.localizedDescription } }
                if let fileURL { ShareLink("Share plan package",item:fileURL) }
                else { Text("Save the plan to share its portable package.") }
                Button("Load plan from JSON…") { showJSONWarning = true }
                Button("Open sample plan") { if store.project.items.isEmpty && store.project.sources.isEmpty { store.openSample(undoManager:undoManager) } else { showSampleWarning = true } }
                if !store.selection.isEmpty { Divider(); Button("Duplicate selected") { store.duplicate(undoManager:undoManager) }.keyboardShortcut("d",modifiers:.command); Button("Delete selected",role:.destructive) { store.remove(undoManager:undoManager) } }
            } label: { Label("Workspace actions",systemImage:"ellipsis.circle") }
        }
    }
    private var trialSheet:some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:20) {
                Image(systemName:"leaf.circle").font(.largeTitle)
                Text("Free plan: up to 12 features per plan.").font(.title2.bold())
                Text("You can keep opening, editing, and exporting all your existing work, including plans with more than 12 features. Delete a feature to add a different one.")
                Text("Unlimited features and rendering credit will be available with the paid unlock when purchases launch. No purchase is available in this build.").foregroundStyle(.secondary)
                Button("Continue editing") { store.showTrialLimit = false }.buttonStyle(.borderedProminent)
            }.padding(24).frame(maxWidth:420).navigationTitle("Free plan").toolbar { Button("Done") { store.showTrialLimit = false } }
        }
    }
    private var urlImportSheet:some View {
        NavigationStack {
            Form {
                Text("Import page metadata and retain its original response. Linked images are not downloaded.")
                TextField("https://…",text:$urlText).textContentType(.URL)
                Button("Import page") { let value = urlText; urlSheet = false; runImport { try await ImportService.url(value) } }.disabled(urlText.isEmpty || importing)
            }.navigationTitle("Import page URL").toolbar { Button("Cancel") { urlSheet = false } }
        }.frame(minWidth:320,minHeight:260)
    }
    private func runImport(_ work:@escaping @Sendable () async throws -> PreparedImport) {
        importing = true
        Task { defer { importing = false }; do { try store.importPrepared(try await work(),undoManager:undoManager); sources = true } catch { store.error = error.localizedDescription } }
    }
    private func importPlanJSON(_ result:Result<URL,Error>) {
        Task {
            do {
                let url = try result.get()
                let data = try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size <= 8 * 1024 * 1024 else { throw EngineError(code:"IMPORT_LIMIT",message:"The plan JSON exceeds 8 MB.") }
                    return try Data(contentsOf:url)
                }.value
                try store.replace(with:data,undoManager:undoManager)
            } catch { store.error = error.localizedDescription }
        }
    }
}

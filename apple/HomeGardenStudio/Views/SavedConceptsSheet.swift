import SwiftUI
import UniformTypeIdentifiers

struct SavedConceptsSheet: View {
    @ObservedObject var document: PlanDocument
    @Environment(\.dismiss) private var dismiss
    @State private var export: PNGExport?
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Text("AI concept images retained inside this plan. These are visual suggestions, not measured geometry.").font(.callout)
                ForEach(document.renderRecords) { record in
                    if let data = document.render(named: record.filename) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(record.title).font(.headline)
                            RenderImagePreview(bytes: data).frame(height: 280)
                            Text("\(record.provider) · \(record.createdAt.formatted())").font(.caption)
                            Button("Export PNG") { export = PNGExport(data: data); exporting = true }
                        }.padding(.vertical, 8)
                    }
                }
                if document.renderRecords.isEmpty { ContentUnavailableView("No saved concepts", systemImage: "photo.stack", description: Text("Save a completed concept image to keep it with this plan.")) }
            }.navigationTitle("Saved concept images").toolbar { Button("Done") { dismiss() } }
                .fileExporter(isPresented: $exporting, document: export, contentType: .png, defaultFilename: "Garden concept") { if case .failure(let failure) = $0 { error = failure.localizedDescription } }
                .alert("Export notice", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }.frame(minWidth: 320, minHeight: 450)
    }
}
nonisolated struct PNGExport: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

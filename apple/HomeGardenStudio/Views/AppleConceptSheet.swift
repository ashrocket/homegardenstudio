import SwiftUI
import ImagePlayground

struct AppleConceptSheet: View {
    let store: PlanStore
    var body: some View { AppleConceptSession(store: store).id(ObjectIdentifier(store.document)) }
}

private struct AppleConceptSession: View {
    let store: PlanStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.supportsImagePlayground) private var supported
    @State private var preference = ""
    @State private var photoID = ""
    @State private var prepared: Prepared?
    @State private var launch: Launch?
    @State private var presented = false
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var ticket = UUID()
    @State private var savedPNG: Data?
    @State private var notice: String?

    private struct Prepared {
        let input: AppleConceptImage.Input
        let document: PlanDocument
        let revision: Int
        let layout: CGImage
        let photo: CGImage?
        var concepts: [ImagePlaygroundConcept] {
            var result: [ImagePlaygroundConcept] = [.text(input.prompt), .image(layout)]
            if let photo { result.append(.image(photo)) }
            return result
        }
    }
    private struct Launch {
        let id: UUID
        let prepared: Prepared
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple image concepts") {
                    Text("Explore an approximate visual idea with Apple Image Playground. It may change positions, shapes and dimensions; the result is not measured geometry.")
                    Text("Apple manages generation, device availability and usage limits. Apple Intelligence may use Apple Private Cloud Compute; this is not a promise of offline processing. Only Apple's illustration, sketch and animation styles are offered here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if supported {
                    Section("Prepare your references") {
                        TextField("Describe the look (optional)", text: $preference, axis: .vertical).lineLimit(2...5)
                        Picker("Optional imported photo", selection: $photoID) {
                            Text("No photo").tag("")
                            ForEach(store.project.sources.filter { $0.kind == "photo" }) { source in
                                Text(source.title).tag(source.id)
                            }
                        }
                        Text("The layout drawing is always included. Choosing a photo explicitly includes a resized copy for processing by Apple's service. Your original remains in the plan. You can also change inputs inside Apple's sheet.")
                            .font(.caption)
                        Button("Prepare references") { prepare() }.disabled(busy || presented)
                    }.disabled(busy || presented)
                    if let prepared {
                        Section("Review what will open in Image Playground") {
                            RenderImagePreview(bytes: prepared.input.layoutPNG).frame(height: 240)
                                .accessibilityLabel("Frozen layout reference for Apple Image Playground")
                            if let photo = prepared.input.photoPNG {
                                RenderImagePreview(bytes: photo).frame(height: 180).accessibilityLabel("Selected photo reference")
                            }
                            Text(prepared.input.prompt).font(.caption).textSelection(.enabled)
                            Text("This records the plan and references supplied now. Apple does not return a record of changes you make inside its sheet.").font(.caption)
                            Button("Open Apple Image Playground") { begin(prepared) }
                                .disabled(busy || presented || prepared.revision != store.revision)
                            if prepared.revision != store.revision { Text("The plan changed. Prepare new references before continuing.").foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    ContentUnavailableView("Image Playground unavailable", systemImage: "photo.badge.exclamationmark",
                        description: Text("Apple determines availability for this device, language, region and settings. You can keep editing and using the local plan, isometric and 3D views."))
                }
                if busy { ProgressView("Preparing image on this device") }
                if let notice { Section { Text(notice).accessibilityIdentifier("appleConcept.notice") } }
                if let savedPNG {
                    Section("Added to this plan") {
                        RenderImagePreview(bytes: savedPNG).frame(height: 280)
                        Text("Apple Image Playground · approximate concept. The plan's measured geometry is unchanged. Save or export the document to retain the image with it.").font(.caption)
                    }
                }
            }
            .navigationTitle("Apple concept image")
            .toolbar { Button("Done") { invalidate(); dismiss() }.disabled(busy || presented) }
            .background {
                if let launch {
                    Color.clear
                        .imagePlaygroundSheet(isPresented: $presented, concepts: launch.prepared.concepts,
                            onCompletion: { url in complete(url, launch: launch) },
                            onCancellation: { cancel(launch) })
                        .imagePlaygroundGenerationStyle(.illustration, in: [.illustration, .sketch, .animation])
                }
            }
            .onChange(of: preference) { _, _ in prepared = nil }
            .onChange(of: photoID) { _, _ in prepared = nil }
            .onDisappear { invalidate() }
        }
        .frame(minWidth: 320, minHeight: 480)
        .interactiveDismissDisabled(busy || presented)
    }

    private func prepare() {
        guard supported, !busy, !presented else { return }
        let document = store.document, revision = store.revision, requested = preference
        let source = store.project.sources.first { $0.id == photoID }
        let original = source?.sha256.flatMap { document.original(sha: $0) }
        let selectedPhoto = !photoID.isEmpty
        let current = UUID(); ticket = current; busy = true; notice = nil; prepared = nil
        work = Task {
            defer { if ticket == current { busy = false } }
            do {
                guard requested.utf8.count <= 2000 else { throw AppleConceptImage.Failure.invalidInput }
                if selectedPhoto && (source?.kind != "photo" || original == nil) { throw AppleConceptImage.Failure.invalidInput }
                let projectJSON = try store.engine.snapshot()
                let brief = try store.engine.query(EngineQuery("render_brief"), as: RenderBrief.self).get()
                let prompt = "Garden concept based on the supplied layout drawing. Preserve its arrangement where possible; never treat this illustration as measured evidence. "
                    + String(brief.prompt.prefix(4000)) + "\nUncertainty: " + String(brief.uncertainties.joined(separator: "; ").prefix(1000))
                    + "\nLook preference: " + requested
                let layoutPNG = try await LayoutImageExport.png(store: store, includeBackdrop: false)
                let photoJPEG: Data?
                if let original { photoJPEG = try await LayoutImageExport.referenceJPEG(original) } else { photoJPEG = nil }
                let projectID = document.projectID
                let decoded = try await Task.detached(priority: .userInitiated) {
                    let photoPNG = try photoJPEG.map { try AppleConceptImage.normalizedPNG($0) }
                    let input = try AppleConceptImage.Input(projectID: projectID, projectJSON: projectJSON, prompt: prompt, layoutPNG: layoutPNG, photoPNG: photoPNG)
                    return (input, try AppleConceptImage.decodedImage(layoutPNG), try photoPNG.map { try AppleConceptImage.decodedImage($0) })
                }.value
                guard !Task.isCancelled, ticket == current else { return }
                guard store.document === document, store.revision == revision else { throw AppleConceptImage.Failure.wrongDocument }
                prepared = Prepared(input: decoded.0, document: document, revision: revision, layout: decoded.1, photo: decoded.2)
            } catch { if !Task.isCancelled, ticket == current { notice = error.localizedDescription } }
        }
    }

    private func begin(_ prepared: Prepared) {
        guard supported, !busy, !presented, prepared.document === store.document, prepared.revision == store.revision else { return }
        let id = UUID(); ticket = id; launch = Launch(id: id, prepared: prepared); notice = nil; presented = true
    }

    private func complete(_ url: URL, launch: Launch) {
        guard self.launch?.id == launch.id, ticket == launch.id,
              launch.prepared.document === store.document, !busy else { return }
        presented = false
        do {
            // Open synchronously while Apple's temporary URL is valid; decode on a worker.
            let file = try AppleConceptImage.OpenedFile(url: url)
            busy = true
            work = Task {
                defer { if ticket == launch.id { busy = false; self.launch = nil } }
                do {
                    let png = try await Task.detached(priority: .userInitiated) { try file.normalize() }.value
                    guard !Task.isCancelled, ticket == launch.id else { return }
                    guard launch.prepared.document === store.document else { throw AppleConceptImage.Failure.wrongDocument }
                    try AppleConceptImage.attach(png, input: launch.prepared.input, to: store.document)
                    savedPNG = png; notice = nil
                } catch { if !Task.isCancelled, ticket == launch.id { notice = error.localizedDescription } }
            }
        } catch { notice = error.localizedDescription; self.launch = nil }
    }

    private func cancel(_ launch: Launch) {
        // Completion owns the result once normalization begins. A late system
        // cancellation must not invalidate that operation or strand its busy state.
        guard self.launch?.id == launch.id, ticket == launch.id, !busy else { return }
        invalidate(); notice = "Cancelled. No concept was added to the plan."
    }

    private func invalidate() {
        ticket = UUID(); work?.cancel(); work = nil
        busy = false; launch = nil; presented = false
    }
}

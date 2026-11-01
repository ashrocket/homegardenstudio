import SwiftUI
import ImageIO

struct CloudRenderSheet: View {
    var store: PlanStore
    var account: AccountService
    @Bindable var renderer: RenderRecoveryService
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: RenderModelCatalog?
    @State private var provider: CloudRenderProvider = .managed
    @State private var model = ""
    @State private var size = ""
    @State private var quality = ""
    @State private var style = ""
    @State private var includeBackdrop = false
    @State private var referenceID = ""
    @State private var input: RenderInput?
    @State private var preparedRevision: Int?
    @State private var consent = false
    @State private var draft: RenderQuoteDraft?
    @State private var approved = false
    @State private var preparing = false
    @State private var submitting = false
    @State private var notice: String?
    @State private var deleteEntry: RenderRecoveryEntry?
    @State private var saved: SavedRenderResult?
    private var busy: Bool { preparing || submitting || renderer.isBusy }
    private var modelOptions: RenderModelCatalog.Model? { catalog?.providers.first { $0.provider == provider }?.models.first { $0.id == model } }
    private var optionsIdentity: String { [provider.rawValue, model, size, quality, style, referenceID, String(includeBackdrop)].joined(separator: "\n") }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Cloud images are AI concepts, not measured plans. Local plan, isometric and 3D views stay free.").font(.callout)
                    if account.entitlementEnvironment == .sandbox { Label("Sandbox account · test balances", systemImage: "testtube.2").font(.caption) }
                }
                Section("Prepare a concept") {
                    if let catalog, !catalog.providers.isEmpty {
                        Picker("Provider", selection: $provider) { ForEach(catalog.providers, id: \.provider) { Text($0.provider.rawValue.capitalized).tag($0.provider) } }
                            .onChange(of: provider) { _, _ in chooseModel() }
                        Picker("Model", selection: $model) { ForEach(catalog.providers.first { $0.provider == provider }?.models ?? []) { Text($0.id).tag($0.id) } }
                            .onChange(of: model) { _, _ in chooseFormat() }
                        Picker("Image size", selection: $size) { ForEach(modelOptions?.sizes ?? [], id: \.self) { Text($0).tag($0) } }
                        Picker("Quality", selection: $quality) { ForEach(modelOptions?.qualities ?? [], id: \.self) { Text($0.capitalized).tag($0) } }
                        TextField("Style preference (optional)", text: $style, axis: .vertical).lineLimit(2...4)
                        if store.project.backdrop != nil { Toggle("Include the photo backdrop in the layout image", isOn: $includeBackdrop) }
                        Picker("Optional reference photo", selection: $referenceID) {
                            Text("No reference photo").tag("")
                            ForEach(store.project.sources.filter { $0.kind == "photo" }) { Text($0.title).tag($0.id) }
                        }
                        Text("Reference photos are resized for the request. The original stays unchanged in your plan.").font(.caption)
                        Button("Prepare images for review") { prepareInput() }.disabled(busy || model.isEmpty || size.isEmpty || quality.isEmpty)
                    } else { Text("No image models are available from the configured service.").foregroundStyle(.secondary); Button("Refresh model availability") { load() }.disabled(busy) }
                    if preparing { ProgressView("Preparing images on this device") }
                }.disabled(busy)
                if let input {
                    Section("Review uploads") {
                        RenderImagePreview(bytes: input.layoutPNG).frame(height: 260).accessibilityLabel("Exact layout image prepared for upload")
                        if let reference = input.sourceImage { RenderImagePreview(bytes: reference).frame(height: 200).accessibilityLabel("Resized reference photo prepared for upload") }
                        Text("The quote request sends these images and the plan prompt to the account service now. Generation begins only after a separate quote approval.").font(.caption)
                        Toggle("I approve uploading this layout and every included photo", isOn: $consent).disabled(busy)
                        Button("Upload approved inputs and get quote") {
                            Task {
                                do {
                                    guard consent, preparedRevision == store.revision else { throw RenderRecoveryError.consentRequired }
                                    let requestedRevision = preparedRevision
                                    let result = try await renderer.quote(input: input, projectID: store.document.projectID, photoUploadConsent: true)
                                    guard self.input != nil, preparedRevision == requestedRevision, preparedRevision == store.revision else { throw EngineError(code: "PLAN_CHANGED", message: "The plan or request changed. Review fresh inputs before approving a quote.") }
                                    draft = result; approved = false; notice = nil
                                } catch { notice = error.localizedDescription }
                            }
                        }.disabled(!consent || busy || draft != nil)
                    }
                }
                if let draft {
                    Section("Approve exact quote") {
                        LabeledContent("Destination", value: draft.quote.destinationHost)
                        LabeledContent("Provider / model", value: "\(draft.quote.provider.rawValue) / \(draft.quote.model)")
                        LabeledContent("Size / quality", value: "\(draft.quote.size) / \(draft.quote.quality)")
                        LabeledContent("Gateway debit", value: CreditDisplay.usd(draft.quote.debitMicros))
                        LabeledContent("Funding", value: funding(draft.quote.funding))
                        Text("Quote expires \(draft.quote.expiry.formatted(date: .omitted, time: .standard)).").font(.caption)
                        if draft.quote.providerBilling { Text("Your provider bills this request separately. A zero gateway debit is not a free-image promise.").font(.caption) }
                        Toggle("Approve this destination, frozen inputs and quoted debit", isOn: $approved)
                        Button("Submit approved cloud render") { submit(draft) }.buttonStyle(.borderedProminent).disabled(!approved || busy || draft.quote.expiry <= Date())
                    }
                }
                if let notice { Section { Text(notice).font(.callout).textSelection(.enabled) } }
                recoverySection
                if let saved {
                    Section(saved.label) {
                        RenderImagePreview(bytes: saved.png).frame(height: 300)
                        ShareLink("Export saved PNG", item: saved.fileURL)
                        Text("The image is saved in device recovery storage. Attaching it to a document is separate from saving that document.").font(.caption)
                    }
                }
            }.formStyle(.grouped).navigationTitle("Cloud concepts and recovery")
                .toolbar { Button("Done") { dismiss() } }
                .task { load() }
                .onChange(of: optionsIdentity) { _, _ in invalidateInput() }
                .onChange(of: store.revision) { _, _ in invalidateInput() }
                .confirmationDialog("Remove this device's recovery copy?", isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }), titleVisibility: .visible) {
                    Button("Remove recovery copy", role: .destructive) {
                        guard let entry = deleteEntry else { return }
                        Task { do { try await renderer.deleteRecovery(id: entry.id, confirmed: true); deleteEntry = nil } catch { notice = error.localizedDescription } }
                    }
                } message: { Text("Export the PNG or save its attached plan first. This removes the local recovery copy, not a saved plan attachment, and does not refund a cloud charge.") }
        }.frame(minWidth: 340, minHeight: 520)
    }
    private var recoverySection: some View {
        Section("Saved requests and recovery") {
            Text("Requests retain one retry identity. After a timeout, use Recover; do not create a replacement paid request. Server retrieval lasts seven days.").font(.caption)
            Button("Reload device recovery records") { Task { do { try await renderer.reload() } catch { notice = error.localizedDescription } } }.disabled(busy)
            ForEach(renderer.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(entry.quote.model) · \(entry.createdAt.formatted())").font(.headline)
                    Text(status(entry)).font(.caption)
                    if entry.projectID != store.document.projectID { Text("Belongs to another plan. Open that plan to attach its image.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Recover / check status") { Task { do { _ = try await renderer.recover(id: entry.id); notice = "Recovery checked using the saved request identity." } catch { notice = error.localizedDescription } } }.disabled(busy)
                        if entry.result != nil && entry.projectID == store.document.projectID { Button("View and attach") { attach(entry) }.disabled(busy) }
                        if !entry.state.isUnresolved { Button("Remove…", role: .destructive) { deleteEntry = entry }.disabled(busy) }
                    }
                }.padding(.vertical, 4)
            }
            if renderer.entries.isEmpty { Text("No recovery records for this account on this device.").foregroundStyle(.secondary) }
        }
    }
    private func load() {
        Task {
            do { try await renderer.reload() } catch { notice = error.localizedDescription }
            do { catalog = try await renderer.fetchModels(); if let first = catalog?.providers.first { provider = first.provider; chooseModel() } }
            catch { notice = error.localizedDescription }
        }
    }
    private func chooseModel() { model = catalog?.providers.first { $0.provider == provider }?.models.first?.id ?? ""; chooseFormat() }
    private func chooseFormat() { size = modelOptions?.sizes.first ?? ""; quality = modelOptions?.qualities.first ?? "" }
    private func invalidateInput() { input = nil; preparedRevision = nil; draft = nil; consent = false; approved = false }
    private func prepareInput() {
        preparing = true; notice = nil; invalidateInput()
        let revision = store.revision, selectedProvider = provider, selectedModel = model, selectedSize = size, selectedQuality = quality, selectedStyle = style
        let source = store.project.sources.first { $0.id == referenceID }
        let original = source?.sha256.flatMap { store.document.original(sha: $0) }
        let selectedBackdrop = includeBackdrop
        Task {
            defer { preparing = false }
            do {
                guard selectedStyle.utf8.count <= 2000 else { throw RenderRecoveryError.invalidInput }
                if source != nil && original == nil { throw EngineError(code: "MISSING_ATTACHMENT", message: "The selected reference original is missing.") }
                let brief = try store.engine.query(EngineQuery("render_brief"), as: RenderBrief.self).get()
                let png = try await LayoutImageExport.png(store: store, includeBackdrop: selectedBackdrop)
                let reference: Data?
                if let original { reference = try await LayoutImageExport.referenceJPEG(original) } else { reference = nil }
                guard store.revision == revision else { throw EngineError(code: "PLAN_CHANGED", message: "The plan changed while preparing images. Prepare them again before uploading.") }
                let prompt = brief.prompt + "\nUncertainties:\n" + brief.uncertainties.joined(separator: "\n") + "\nStyle preference: " + selectedStyle + "\nRetain the supplied layout and source context. This is an AI concept, not measured evidence."
                let candidate = RenderInput(provider: selectedProvider, model: selectedModel, size: selectedSize, quality: selectedQuality, prompt: prompt, layoutPNG: png, sourceImage: reference, sourceMediaType: reference == nil ? nil : .jpeg)
                try candidate.validate(); input = candidate; preparedRevision = revision
            } catch { notice = error.localizedDescription }
        }
    }
    private func submit(_ draft: RenderQuoteDraft) {
        guard approved else { return }
        submitting = true; notice = nil
        Task {
            defer { submitting = false; self.draft = nil; approved = false }
            do { let entry = try await renderer.submit(draft, approved: true); notice = status(entry) }
            catch { notice = error.localizedDescription + " Use the saved recovery record to check or retry this request." }
            try? await renderer.reload()
        }
    }
    private func attach(_ entry: RenderRecoveryEntry) {
        Task {
            do {
                guard let result = try await renderer.savedResult(id: entry.id, projectID: store.document.projectID) else { throw RenderRecoveryError.resultUnavailable }
                let record = RenderAttachmentRecord(id: entry.id, projectID: result.projectID, filename: result.image.sha256 + ".png", title: result.label, provider: entry.quote.provider.rawValue, inputDigest: entry.quote.inputDigest, createdAt: entry.createdAt)
                try store.document.attachRender(result.png, record: record)
                saved = result; notice = "Attached to this plan. Save or export the plan to keep a portable copy; the device recovery copy remains available."
            } catch { notice = error.localizedDescription }
        }
    }
    private func funding(_ funding: RenderFunding) -> String { switch funding { case .balance: "Prepaid account balance"; case .sponsorWindow: "Approved finite sponsorship window"; case .provider: "Your provider bills separately" } }
    private func status(_ entry: RenderRecoveryEntry) -> String {
        var message: String
        switch entry.state {
        case .prepared: message = "Saved request, not yet confirmed by the server."
        case .uncertain: message = "Outcome uncertain. Recover using this existing request identity."
        case .pending: message = "The server is processing this request."
        case .saved: message = "Image saved durably on this device; acknowledgement may still be pending."
        case .acknowledged: message = "Image saved durably and acknowledged to the server."
        case .failed: message = "The render failed."
        case .unavailable: message = "A server image is no longer available; check the saved status."
        }
        if entry.refunded { message += " Gateway debit refunded." }
        if entry.quote.providerBilling { message += " Provider billing is separate and cannot be reversed here." }
        return message
    }
}

struct RenderImagePreview: View {
    let bytes: Data
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        Group { if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else if failed { ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark") } else { ProgressView("Loading image") } }
            .task(id: bytes) {
                image = nil; failed = false
                let result = await Task.detached(priority: .userInitiated) {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                image = result; failed = result == nil
            }
    }
}

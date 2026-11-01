import SwiftUI

struct AssistantSheet: View {
    var store: PlanStore
    var services: StudioServices
    @Environment(\.dismiss) private var dismiss
    @State private var local = LocalAssistant()
    @State private var task: GardenAssistTask = .critique
    @State private var route = "apple"
    @State private var question = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var provider: GatewayProvider = .openai
    @State private var cloudConsent = false
    @State private var cloudOutput = ""
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("Engine checks first") {
                    if store.issues.isEmpty { Text("No geometry warnings found. This is not a survey or safety certification.").font(.caption) }
                    ForEach(Array(store.issues.enumerated()), id: \.offset) { _, issue in Label(issue.message, systemImage: "exclamationmark.triangle").font(.caption) }
                }
                Section("Ask for suggestions") {
                    Picker("Task", selection: $task) { ForEach(GardenAssistTask.allCases) { Text($0.title).tag($0) } }
                    TextField("Question or preferences (optional)", text: $question, axis: .vertical).lineLimit(2...5)
                    Picker("Assistant", selection: $route) { Text("Apple on-device").tag("apple"); Text("My local endpoint").tag("loopback"); if services.account?.accountID != nil { Text("My cloud provider").tag("cloud") } }
                        .onChange(of: route) { _, _ in cloudConsent = false; notice = nil }
                    if route == "apple" {
                        if let reason = local.availability { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        Text("Uses the on-device language model when supported. No cloud fallback or model download is started by this app.").font(.caption)
                    } else if route == "loopback" {
                        TextField("Full loopback chat endpoint", text: $endpoint)
                        TextField("Local model name", text: $model)
                        Text("Start your compatible model server yourself. Only this device's loopback addresses are accepted. Your server controls its model and any forwarding. No model is downloaded and no API key is sent.").font(.caption)
                    } else {
                        Picker("Provider", selection: $provider) {
                            ForEach(services.account?.snapshot?.keys ?? []) { key in Text(key.provider.rawValue.capitalized).tag(key.provider) }
                        }.onChange(of: provider) { _, _ in cloudConsent = false }
                        Toggle("Send this plan's text and question to my selected provider", isOn: $cloudConsent)
                        Text("This sends layout context through the account service. Your provider bills text usage separately. No photos are sent by this text request.").font(.caption)
                    }
                    Button("Generate reviewable suggestions") { generate() }
                        .disabled(local.isWorking || operation != nil || (route == "apple" && local.availability != nil) || (route == "cloud" && !cloudConsent))
                    if operation != nil { Button("Cancel request", role: .cancel) { operation?.cancel(); notice = "Cancelling request…" }; ProgressView() }
                    Text("Suggestions do not change geometry, measurements, source provenance or plant identification.").font(.caption).foregroundStyle(.secondary)
                }
                if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
                if !local.output.isEmpty { Section(local.outputLabel) { Text(local.output).textSelection(.enabled) } }
                if !cloudOutput.isEmpty { Section("Cloud provider suggestion · review before using") { Text(cloudOutput).textSelection(.enabled) } }
                if !store.project.sources.filter({ $0.kind == "photo" }).isEmpty {
                    Section("Inspect a source on this device") {
                        ForEach(store.project.sources.filter { $0.kind == "photo" }) { source in NavigationLink(source.title) { LocalSourceAnalysisView(store: store, source: source) } }
                    }
                }
            }.formStyle(.grouped).navigationTitle("Garden assistant").toolbar { Button("Done") { dismiss() } }
                .onChange(of: question) { _, _ in cloudConsent = false }
                .onChange(of: task) { _, _ in cloudConsent = false }
                .onChange(of: store.revision) { _, _ in cloudConsent = false }
                .onDisappear { operation?.cancel() }
        }.frame(minWidth: 320, minHeight: 480)
    }
    private func generate() {
        notice = nil
        let selectedTask = task, selectedRoute = route, selectedProvider = provider, selectedQuestion = question
        let selectedEndpoint = endpoint, selectedModel = model, approvedCloud = cloudConsent
        let context: String
        do {
            let brief = try store.engine.query(EngineQuery("render_brief"), as: RenderBrief.self).get()
            context = brief.prompt + "\nUncertainties:\n" + brief.uncertainties.joined(separator: "\n")
        } catch { notice = error.localizedDescription; return }
        operation = Task {
            defer { operation = nil }
            do {
                if selectedRoute == "apple" { try await local.useApple(task: selectedTask, brief: context, question: selectedQuestion) }
                else if selectedRoute == "loopback" { try await local.useLoopback(configuration: LocalModelConfiguration(endpoint: selectedEndpoint, model: selectedModel), task: selectedTask, brief: context, question: selectedQuestion) }
                else {
                    guard approvedCloud, let account = services.account else { throw GatewayError.confirmationRequired }
                    let cloudTask: AssistTask = selectedTask == .plantIdeas ? .plantIdeas : selectedTask == .describe ? .describe : .critique
                    let response = try await account.assist(provider: selectedProvider, task: cloudTask, layoutBrief: context, question: selectedQuestion)
                    try Task.checkCancellation(); cloudOutput = response.text
                }
            } catch is CancellationError { notice = "Request cancelled. A cloud provider may still have billed an already accepted request." }
            catch { notice = error.localizedDescription }
        }
    }
}

private struct LocalSourceAnalysisView: View {
    var store: PlanStore
    let source: Source
    @State private var result: LocalEvidenceResult?
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Form {
            Text("OCR and image labels run on this device. They may be wrong and cannot establish measured positions or verified plant species.").font(.callout)
            Button("Analyze original locally") {
                guard let sha = source.sha256, let bytes = store.document.original(sha: sha) else { error = "The original attachment is missing."; return }
                working = true
                Task { defer { working = false }; do { result = try await LocalEvidenceAnalysis.analyze(bytes) } catch { self.error = error.localizedDescription } }
            }.disabled(working)
            if working { ProgressView("Analyzing on device") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let result {
                Section("Recognized text · unverified") { Text(result.text.isEmpty ? "No text recognized." : result.text).textSelection(.enabled); if let language = result.language { Text("Detected language: \(language)").font(.caption) } }
                Section("Image label guesses") { ForEach(result.observations) { value in LabeledContent(value.label, value: String(format: "%.0f%% confidence", value.confidence * 100)) }; if result.observations.isEmpty { Text("No sufficiently confident labels.") } }
            }
        }.navigationTitle(source.title)
    }
}

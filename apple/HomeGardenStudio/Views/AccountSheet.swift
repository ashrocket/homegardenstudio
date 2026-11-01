import SwiftUI

struct AccountSheet: View {
    @Bindable var services: StudioServices
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var deleteAccount = false
    @State private var sponsorship = false
    @State private var recoveryAccounts: [RecoverableAccount] = []
    @State private var recoveryPicker = false
    @State private var budget = ""
    @State private var capEnabled = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if services.isPreparing { ProgressView("Checking account availability") }
                    if let message = services.setupMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if let message = services.renderSetupMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if let account = services.account {
                        Text(accountStatus(account)).font(.callout)
                        if let id = account.accountID { LabeledContent("Account", value: id.uuidString).font(.caption).textSelection(.enabled) }
                        if account.state == .recoveryRequired || account.state == .notLoaded { Button("Retry saved account") { Task { await services.retrySetup() } } }
                        Button("Choose a preserved account…") {
                            do { recoveryAccounts = try account.recoverableAccounts(); recoveryPicker = true }
                            catch { self.error = error.localizedDescription }
                        }.disabled(account.isBusy)
                        if account.state == .signedOut { Button("Create cloud account") { run { try await account.createAccount() } } }
                        if account.accountID != nil { Button("Refresh account") { run { try await account.refresh() } }.disabled(account.isBusy) }
                        if account.state == .credentialSaveRequired { Button("Retry secure account save") { do { try account.retryCredentialSave() } catch { self.error = error.localizedDescription } } }
                    } else { Button("Retry service setup") { Task { await services.retrySetup() } } }
                    Text("Account credentials sync through Keychain. Creating an account does not upload garden photos or buy anything.").font(.caption).foregroundStyle(.secondary)
                }
                if let account = services.account, let snapshot = account.snapshot {
                    Section("Rendering credit") {
                        LabeledContent(snapshot.entitlementEnvironment == .sandbox ? "Sandbox credit · testing only" : "Prepaid credit", value: CreditDisplay.usd(snapshot.entitlementEnvironment == .sandbox ? snapshot.balances.sandbox : snapshot.balances.production))
                        Text(snapshot.managedRender.available ? "Managed rendering is available. Every request shows its actual quoted debit before submission." : (snapshot.managedRender.reason ?? "Managed rendering is unavailable.")).font(.caption)
                        Text("Local plans, isometric views and 3D previews use no cloud credit.").font(.caption)
                    }
                    Section("Monthly spending ceiling") {
                        LabeledContent("Spent this month", value: CreditDisplay.usd(snapshot.monthSpentMicros))
                        Toggle("Set a hard cap", isOn: $capEnabled)
                        if capEnabled { TextField("Cap in US dollars (0–500)", text: $budget) }
                        Button("Save cap") {
                            if capEnabled {
                                guard let micros = CreditDisplay.parseBudget(budget) else { error = "Enter a US dollar amount between 0 and 500, with no more than six decimal places."; return }
                                run { try await account.setBudget(micros: micros) }
                            } else { run { try await account.setBudget(micros: nil) } }
                        }.disabled(account.isBusy)
                        Text("This is a ceiling on prepaid spending. It does not buy credit, create a subscription, or permit automatic overages.").font(.caption).foregroundStyle(.secondary)
                    }.onAppear { capEnabled = snapshot.monthlyCapMicros != nil; if let value = snapshot.monthlyCapMicros { budget = NSDecimalNumber(decimal: Decimal(value) / 1_000_000).stringValue } }
                    Section("Provider keys") { ProviderSettings(account: account) }
                    if snapshot.sponsorshipAvailable { Section { Button("View optional funded sponsorship") { sponsorship = true } } }
                }
                if let purchases = services.purchases, let account = services.account {
                    Section("Unlocks and credit") {
                        Text(account.isUnlocked ? "This platform is unlocked." : "Free plan: add up to 12 features. Existing work remains editable and exportable.")
                        if purchases.products.isEmpty { Text("Prices and products load directly from the App Store. Unavailable products cannot be purchased.").font(.caption) }
                        Button("Load App Store products") { run { try await purchases.loadProducts() } }.disabled(account.accountID == nil)
                        ForEach(purchases.products) { product in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(product.name).font(.headline)
                                Text(product.detail).font(.caption)
                                Button("Buy for \(product.displayPrice)") { run { try await purchases.purchase(productID: product.id) } }.disabled(purchases.state == .purchasing)
                            }
                        }
                        Text(purchaseStatus(purchases.state)).font(.caption)
                        Button("Restore purchases") { run { try await purchases.restore() } }.disabled(account.accountID == nil)
                        if purchases.state == .serverVerificationPending { Button("Retry unfinished purchases") { run { try await purchases.reconcileUnfinished() } } }
                        Text("Restore uses this existing account. Credits are granted by the server once per qualifying transaction.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let account = services.account, account.accountID != nil {
                    Section { Button("Delete cloud account…", role: .destructive) { deleteAccount = true } }
                }
            }.formStyle(.grouped).navigationTitle("Account and rendering")
                .toolbar { Button("Done") { dismiss() } }
                .task { await services.prepare() }
                .sheet(isPresented: $recoveryPicker) {
                    NavigationStack {
                        List {
                            Text("Choose the account identity you want to use. Other preserved identities remain in Keychain. Credit, purchases and provider keys are not transferred between accounts.").font(.callout)
                            if recoveryAccounts.isEmpty { Text("No preserved account identities are available for this service.") }
                            ForEach(recoveryAccounts, id: \.id) { candidate in
                                Button(candidate.id.uuidString) {
                                    guard let account = services.account else { return }
                                    do { try account.recoverStoredAccount(accountID: candidate.id); recoveryPicker = false; run { try await account.refresh() } }
                                    catch { self.error = error.localizedDescription }
                                }.font(.caption.monospaced())
                            }
                        }.navigationTitle("Recover an account").toolbar { Button("Cancel") { recoveryPicker = false } }
                    }.frame(minWidth: 320, minHeight: 350)
                }
                .sheet(isPresented: $sponsorship) { if let account = services.account { SponsorshipSheet(account: account) } }
                .alert("Account notice", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
                .confirmationDialog("Delete this cloud account?", isPresented: $deleteAccount, titleVisibility: .visible) {
                    Button("Delete account", role: .destructive) { run { try await services.deleteAccount() } }
                } message: { Text("This revokes cloud access and deletes provider keys, server image copies and this account’s device render recovery records. Export recovery images first. Transaction and operational records are retained. Local plans and their attached images remain. Apple purchases are separate; account deletion does not refund them.") }
        }.frame(minWidth: 320, minHeight: 480)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { self.error = error.localizedDescription } } }
    private func accountStatus(_ account: AccountService) -> String {
        switch account.state {
        case .unavailable: "Cloud services are unavailable in this build."
        case .notLoaded: "Account credentials have not been loaded."
        case .signedOut: "No cloud account is saved."
        case .ready: "Account is connected."
        case .offline: "Offline. Cached unlock access is retained; spending requires the server."
        case .recoveryRequired: "Account recovery is required. Saved credentials have been preserved; no replacement account was created."
        case .credentialConflict: "Another preserved account identity was found. Choose an account to continue; no identity or credit has been replaced."
        case .credentialSaveRequired: "The account needs a successful secure Keychain save before continuing."
        case .deletionPending: "Cloud access was revoked; local secure cleanup is still pending. Retry deletion to finish."
        }
    }
    private func purchaseStatus(_ state: PurchaseState) -> String {
        switch state {
        case .idle: ""
        case .loading: "Loading verified products…"
        case .unavailable: "App Store products are unavailable."
        case .purchasing: "Waiting for the App Store…"
        case .pending: "Purchase is pending approval."
        case .cancelled: "Purchase cancelled."
        case .accepted: "Purchase accepted by the server."
        case .pendingPrerequisite: "The server is waiting for the required platform unlock."
        case .revoked: "This transaction is revoked."
        case .serverVerificationPending: "Verification is pending. The transaction stays unfinished for retry."
        case .failed: "The purchase could not be completed. No local credit was granted."
        }
    }
}

private struct ProviderSettings: View {
    @Bindable var account: AccountService
    @State private var provider: GatewayProvider = .openai
    @State private var secret = ""
    @State private var endpoint = ""
    @State private var label = ""
    @State private var confirmed = false
    @State private var notice: String?
    var body: some View {
        ForEach(account.snapshot?.keys ?? []) { metadata in
            VStack(alignment: .leading, spacing: 6) {
                Text(metadata.label ?? metadata.provider.rawValue.capitalized).font(.headline)
                Text("Key fingerprint: \(metadata.fingerprint)").font(.caption.monospaced())
                if let host = metadata.endpointHost { Text(host).font(.caption) }
                HStack {
                    Button("Check model discovery") { Task { do { let result = try await account.testProvider(metadata.provider); notice = result.message + " Generation permission has not been verified." } catch { notice = error.localizedDescription } } }
                    Button("Delete key", role: .destructive) { Task { do { try await account.deleteProvider(metadata.provider) } catch { notice = error.localizedDescription } } }
                }.disabled(account.isBusy)
            }
        }
        DisclosureGroup("Add or replace a provider key") {
            Picker("Provider", selection: $provider) { Text("OpenAI").tag(GatewayProvider.openai); Text("Anthropic · text assistance").tag(GatewayProvider.anthropic); Text("Custom compatible provider").tag(GatewayProvider.custom) }
                .onChange(of: provider) { _, _ in confirmed = false }
            SecureField("Provider key", text: $secret).onChange(of: secret) { _, _ in confirmed = false }
            if let suggestion { Text("Key format suggests \(suggestion). Confirm the provider yourself before sending.").font(.caption) }
            TextField("Key label (optional)", text: $label)
            if provider == .custom { TextField("Explicit HTTPS provider endpoint", text: $endpoint).onChange(of: endpoint) { _, _ in confirmed = false } }
            Toggle("I confirm this key belongs to \(provider.rawValue.capitalized)", isOn: $confirmed)
            Text("The key is sent to the configured account service for encrypted storage. It is never saved in a garden plan. Anthropic is for text assistance, not direct image generation.").font(.caption)
            Button("Store confirmed key securely") {
                let key = secret, selectedProvider = provider, selectedLabel = label
                let selectedEndpoint = provider == .custom ? URL(string: endpoint) : nil
                let confirmation = confirmed ? provider : nil
                Task {
                    do { try await account.saveProvider(selectedProvider, secret: key, confirmedProvider: confirmation, endpoint: selectedEndpoint, label: selectedLabel.isEmpty ? nil : selectedLabel); secret = ""; confirmed = false; notice = "Key saved. Model discovery and generation permissions remain unverified." }
                    catch { notice = error.localizedDescription }
                }
            }.disabled(!confirmed || secret.isEmpty || account.isBusy)
        }.onDisappear { secret = ""; confirmed = false }
        if let notice { Text(notice).font(.caption).textSelection(.enabled) }
    }
    private var suggestion: String? { secret.hasPrefix("sk-ant-") ? "Anthropic" : secret.hasPrefix("sk-") ? "OpenAI" : nil }
}

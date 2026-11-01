import SwiftUI
import Observation

/// One stable entitlement owner serves every open document while account services load.
@Observable @MainActor final class StudioServices: Entitlements {
    private(set) var account: AccountService?
    private(set) var purchases: PurchaseService?
    private(set) var renderer: RenderRecoveryService?
    private(set) var renderSetupMessage: String?
    private(set) var setupMessage: String?
    private(set) var isPreparing = false
    private var prepared = false
    var isUnlocked: Bool { account?.isUnlocked ?? false }

    func prepare() async {
        guard !prepared, !isPreparing else { return }
        isPreparing = true; defer { isPreparing = false; prepared = true }
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "HGSKeychainAccessGroup") as? String else { throw GatewayError.invalidConfiguration }
            let credentials = try KeychainAccountStore(accessGroup: group)
            func configuredURL(_ key: String) -> URL? {
                guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                      !value.isEmpty, !value.contains("$(") else { return nil }
                return URL(string: value)
            }
            let production = configuredURL("HGSProductionGatewayURL")
            let sandbox = configuredURL("HGSSandboxGatewayURL")
            guard production != nil || sandbox != nil else {
                account = AccountService(client: nil, credentials: credentials)
                setupMessage = "Cloud services are not configured in this build. Local editing, previews, imports and exports remain available."
                return
            }
            let selection = try await GatewayEnvironmentSelector.select(productionURL: production, sandboxURL: sandbox)
            let account = AccountService(client: selection.client, credentials: credentials)
            self.account = account
            do { renderer = RenderRecoveryService(account: account, storage: try FileRenderRecoveryStorage.applicationDefault()) }
            catch { renderSetupMessage = "Device render recovery storage is unavailable. " + error.localizedDescription }
            let purchases = PurchaseService(account: account)
            self.purchases = purchases
            purchases.startListening()
            try account.loadStoredAccount()
            if account.accountID != nil {
                do { try await account.refresh(); try await purchases.reconcileUnfinished() }
                catch { setupMessage = error.localizedDescription }
            }
        } catch { setupMessage = error.localizedDescription }
    }
    func retrySetup() async {
        purchases?.stopListening(); purchases = nil; renderer = nil; account = nil
        setupMessage = nil; renderSetupMessage = nil; prepared = false; await prepare()
    }
    func deleteAccount() async throws {
        guard let account else { throw GatewayError.invalidConfiguration }
        // Creating storage again is safe, and ensures deletion cannot silently skip a failed setup.
        let recovery = try renderer ?? RenderRecoveryService(account: account, storage: FileRenderRecoveryStorage.applicationDefault())
        try await account.deleteAccount(confirmed: true, localCleanup: { origin, id in
            try await recovery.deleteAccountRecovery(identity: RenderAccountIdentity(accountId: id, origin: origin), serverDeletionConfirmed: true)
        })
    }
}

nonisolated enum CreditDisplay {
    static func usd(_ micros: Int) -> String {
        let value = Decimal(micros) / Decimal(1_000_000)
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        return formatter.string(from: value as NSDecimalNumber) ?? "USD " + NSDecimalNumber(decimal: value).stringValue
    }
    static func parseBudget(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:[0-9]+(?:\.[0-9]{1,6})?|\.[0-9]{1,6})$"#, options: .regularExpression) != nil, value.count <= 32,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0, decimal <= 500 else { return nil }
        let scaled = decimal * 1_000_000
        var input = scaled, rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled else { return nil }
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

import Foundation
import Observation

nonisolated enum AccountState: Equatable, Sendable {
    case unavailable, notLoaded, signedOut, ready, offline, recoveryRequired, credentialSaveRequired, deletionPending
}

@Observable @MainActor final class AccountService: Entitlements {
    private(set) var state: AccountState
    private(set) var snapshot: GatewayAccount?
    private(set) var isBusy = false
    @ObservationIgnored private let client: GatewayClient?
    @ObservationIgnored private let credentials: any AccountCredentialStore
    private var stored: StoredAccount?
    @ObservationIgnored private var deletedRemotely = false

    var accountID: UUID? { stored?.accountID }
    var gatewayOrigin: String? { client?.origin }
    var entitlementEnvironment: EntitlementEnvironment? { stored?.cachedEntitlements?.environment }
    var isUnlocked: Bool {
        guard let entitlement = stored?.cachedEntitlements?.entitlements else { return false }
        #if os(macOS)
        return entitlement.bundle || entitlement.macos
        #else
        return entitlement.bundle || entitlement.ios
        #endif
    }

    init(client: GatewayClient?, credentials: any AccountCredentialStore) {
        self.client = client
        self.credentials = credentials
        state = client == nil ? .unavailable : .notLoaded
    }

    func loadStoredAccount() throws {
        guard !isBusy else { throw GatewayError.busy }
        guard let client else { throw GatewayError.unavailable }
        guard state != .credentialSaveRequired, !deletedRemotely else { throw GatewayError.credentialSaveRequired }
        do {
            let saved = try credentials.load(origin: client.origin)
            try saved?.validate()
            stored = saved
            snapshot = nil
            state = saved == nil ? .signedOut : .offline
        } catch { state = .recoveryRequired; throw error }
    }

    // This method is called only by an explicit Create Account action, never by restore or refresh.
    func createAccount() async throws {
        guard let client else { throw GatewayError.unavailable }
        try begin(); defer { isBusy = false }
        guard stored == nil else { throw GatewayError.accountExists }
        guard state != .recoveryRequired, state != .deletionPending else { throw GatewayError.credentialsUnavailable }
        do {
            if let existing = try credentials.load(origin: client.origin) {
                try existing.validate()
                stored = existing; state = .offline
                throw GatewayError.accountExists
            }
        } catch GatewayError.accountExists { throw GatewayError.accountExists }
        catch { state = .recoveryRequired; throw error }
        nonisolated struct Created: Decodable, Sendable { let accountId: UUID; let secret: String }
        let result: Created = try await client.request("POST", path: "/v1/accounts")
        let account = StoredAccount(accountID: result.accountId, bearer: result.secret)
        try account.validate()
        stored = account
        do { try credentials.save(account, origin: client.origin); state = .offline }
        catch { state = .credentialSaveRequired; throw GatewayError.credentialSaveRequired }
        try await refreshInside(client: client, account: account)
    }

    func retryCredentialSave() throws {
        guard !isBusy else { throw GatewayError.busy }
        guard let client, let stored, state == .credentialSaveRequired else { throw GatewayError.accountRequired }
        try credentials.save(stored, origin: client.origin)
        state = snapshot == nil ? .offline : .ready
    }

    func refresh() async throws {
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        try await refreshInside(client: client, account: account)
    }

    private func refreshInside(client: GatewayClient, account: StoredAccount) async throws {
        do {
            let result: GatewayAccount = try await client.request("GET", path: "/v1/me", bearer: account.bearer)
            try result.validate(accountID: account.accountID)
            guard client.expectedEnvironment == nil || client.expectedEnvironment == result.entitlementEnvironment else {
                throw GatewayError.invalidResponse
            }
            var updated = account
            updated.cachedEntitlements = CachedEntitlements(entitlements: result.entitlements, environment: result.entitlementEnvironment)
            // Apply revocations in memory even if Keychain is temporarily unavailable.
            stored = updated; snapshot = result
            do { try credentials.save(updated, origin: client.origin) }
            catch { state = .credentialSaveRequired; throw GatewayError.credentialSaveRequired }
            state = .ready
        } catch {
            if state != .credentialSaveRequired { state = error as? GatewayError == .unauthorized ? .recoveryRequired : .offline }
            throw error
        }
    }

    func setBudget(micros: Int?) async throws {
        guard micros.map({ (0...500_000_000).contains($0) }) ?? true else { throw GatewayError.invalidInput }
        nonisolated struct Budget: Encodable {
            let monthlyCapMicros: Int?
            enum CodingKeys: String, CodingKey { case monthlyCapMicros }
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let monthlyCapMicros { try c.encode(monthlyCapMicros, forKey: .monthlyCapMicros) }
                else { try c.encodeNil(forKey: .monthlyCapMicros) }
            }
        }
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        // This endpoint returns JSON; refresh is the sole source of account/credit state.
        let _: BudgetReply = try await client.request("PUT", path: "/v1/me/budget", bearer: account.bearer,
                                                     body: GatewayClient.encode(Budget(monthlyCapMicros: micros)))
        try await refreshInside(client: client, account: account)
    }

    func saveProvider(_ provider: GatewayProvider, secret: String, confirmedProvider: GatewayProvider?,
                      endpoint: URL? = nil, label: String? = nil) async throws {
        guard confirmedProvider == provider else { throw GatewayError.confirmationRequired }
        guard (20...400).contains(secret.utf8.count), secret.utf8.allSatisfy({ (33...126).contains($0) }),
              (label?.utf8.count ?? 0) <= 80 else { throw GatewayError.invalidInput }
        switch provider {
        case .openai: guard secret.hasPrefix("sk-"), !secret.hasPrefix("sk-ant-"), endpoint == nil else { throw GatewayError.invalidInput }
        case .anthropic: guard secret.hasPrefix("sk-ant-"), endpoint == nil else { throw GatewayError.invalidInput }
        case .custom:
            guard let endpoint, let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                  c.scheme == "https", c.host != nil, c.user == nil, c.password == nil,
                  c.query == nil, c.fragment == nil, c.port == nil || c.port == 443,
                  endpoint.absoluteString.utf8.count <= 2048 else { throw GatewayError.invalidInput }
        }
        nonisolated struct Key: Encodable { let secret: String; let confirmedProvider: GatewayProvider; let endpoint: String?; let label: String? }
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        let _: ProviderKeyMetadata = try await client.request("PUT", path: "/v1/keys/" + provider.rawValue,
            bearer: account.bearer, body: GatewayClient.encode(Key(secret: secret, confirmedProvider: provider,
                                                                 endpoint: endpoint?.absoluteString, label: label)))
        try await refreshInside(client: client, account: account)
    }

    func testProvider(_ provider: GatewayProvider) async throws -> ProviderDiscovery {
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        let result: ProviderDiscovery = try await client.request("POST", path: "/v1/keys/" + provider.rawValue + "/test",
            bearer: account.bearer, body: Data("{}".utf8))
        guard !result.generationVerified, !result.capabilities.imageGeneration, !result.capabilities.text,
              ["available", "invalid_response"].contains(result.discovery) else { throw GatewayError.invalidResponse }
        return result
    }

    func deleteProvider(_ provider: GatewayProvider) async throws {
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        try await client.empty("DELETE", path: "/v1/keys/" + provider.rawValue, bearer: account.bearer)
        try await refreshInside(client: client, account: account)
    }

    // Account deletion does not cancel or refund Apple purchases.
    func deleteAccount(confirmed: Bool) async throws {
        guard confirmed else { throw GatewayError.confirmationRequired }
        guard let client, let stored else { throw GatewayError.accountRequired }
        try begin(); defer { isBusy = false }
        if !deletedRemotely {
            try await client.empty("DELETE", path: "/v1/me", bearer: stored.bearer)
            deletedRemotely = true
        }
        snapshot = nil
        self.stored?.cachedEntitlements = nil
        state = .deletionPending
        try credentials.delete(origin: client.origin)
        self.stored = nil
        deletedRemotely = false
        state = .signedOut
    }

    func assist(provider: GatewayProvider, task: AssistTask, layoutBrief: String, question: String? = nil) async throws -> AssistResponse {
        guard !layoutBrief.isEmpty, layoutBrief.utf8.count <= 48_000,
              (question?.utf8.count ?? 0) <= 4000 else { throw GatewayError.invalidInput }
        nonisolated struct Input: Encodable { let provider: GatewayProvider; let task: AssistTask; let layoutBrief: String; let question: String? }
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        let result: AssistResponse = try await client.request("POST", path: "/v1/assist", bearer: account.bearer,
            body: GatewayClient.encode(Input(provider: provider, task: task, layoutBrief: layoutBrief, question: question)), timeout: 90)
        guard result.provider == provider, result.providerBilling else { throw GatewayError.invalidResponse }
        return result
    }

    func acceptPurchase(_ transaction: VerifiedStoreTransaction) async throws -> PurchaseAcceptance {
        let (client, account) = try context()
        guard transaction.accountToken == account.accountID else { throw GatewayError.accountMismatch }
        guard ["Production", "Sandbox"].contains(transaction.environment) else { throw GatewayError.verificationFailed }
        if let expected = client.expectedEnvironment {
            guard transaction.environment.lowercased() == expected.rawValue else { throw GatewayError.verificationFailed }
        }
        try begin(); defer { isBusy = false }
        nonisolated struct Input: Encodable { let signedTransaction: String }
        let result: PurchaseAcceptance = try await client.request("POST", path: "/v1/storekit/transactions",
            bearer: account.bearer, body: GatewayClient.encode(Input(signedTransaction: transaction.signedJWS)))
        guard result.transactionId == transaction.id, result.productId == transaction.productID,
              result.environment == transaction.environment, result.creditGrantedMicros >= 0,
              result.balances.production >= 0, result.balances.sandbox >= 0 else { throw GatewayError.invalidResponse }
        return result
    }

    // Account-bound transport for rendering adapters. No bearer or provider secret leaves this service.
    func authenticatedRequest<Response: Decodable & Sendable>(
        _ method: String, path: String, body: Data? = nil, as type: Response.Type = Response.self,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        return try await client.request(method, path: path, bearer: account.bearer, body: body, as: type, timeout: timeout)
    }

    func authenticatedEmpty(_ method: String, path: String, body: Data? = nil) async throws {
        let (client, account) = try context()
        try begin(); defer { isBusy = false }
        try await client.empty(method, path: path, bearer: account.bearer, body: body)
    }

    private func context() throws -> (GatewayClient, StoredAccount) {
        guard let client else { throw GatewayError.unavailable }
        guard let stored else { throw GatewayError.accountRequired }
        guard state != .credentialSaveRequired else { throw GatewayError.credentialSaveRequired }
        guard state != .recoveryRequired, !deletedRemotely else { throw GatewayError.credentialsUnavailable }
        return (client, stored)
    }
    private func begin() throws {
        guard !isBusy else { throw GatewayError.busy }
        isBusy = true
    }
}

private nonisolated struct BudgetReply: Decodable, Sendable { let monthlyCapMicros: Int? }

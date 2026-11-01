import Foundation

nonisolated enum GatewayError: Error, LocalizedError, Equatable {
    case unavailable, invalidConfiguration, invalidInput, invalidResponse, responseTooLarge
    case transport, unauthorized, server(Int), credentialsUnavailable, corruptCredentials
    case accountExists, accountRequired, busy, confirmationRequired, credentialSaveRequired, credentialConflict
    case productUnavailable, verificationFailed, accountMismatch, prerequisiteRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: "Cloud service is not configured. Local planning remains available."
        case .invalidConfiguration: "The cloud service configuration is invalid."
        case .invalidInput: "Check the supplied values."
        case .invalidResponse: "The service returned an unexpected response."
        case .responseTooLarge: "The service response exceeded the size limit."
        case .transport: "The service could not be reached. Try again when connected."
        case .unauthorized: "This account credential was not accepted. Preserve it for account recovery."
        case .server(let status): "The service could not complete the request (HTTP \(status))."
        case .credentialsUnavailable: "Synchronized Keychain is unavailable. No new account was created."
        case .corruptCredentials: "The saved account could not be read. Preserve Keychain data for recovery."
        case .accountExists: "An account already exists. Use that account to restore purchases."
        case .accountRequired: "Load or deliberately create an account first."
        case .busy: "Another account operation is in progress."
        case .confirmationRequired: "Confirm the selected provider before sending a key."
        case .credentialSaveRequired: "The account was created, but Keychain could not save it. Retry saving before continuing."
        case .credentialConflict: "The saved account identity could not be matched safely. Existing credentials have been preserved. Choose a saved account to recover access."
        case .productUnavailable: "This product is not available from the App Store."
        case .verificationFailed: "The purchase could not be verified. It has not been finished."
        case .accountMismatch: "This purchase belongs to a different account."
        case .prerequisiteRequired: "The required platform unlock has not been verified for this account."
        }
    }
}

nonisolated enum GatewayProvider: String, Codable, CaseIterable, Sendable { case openai, anthropic, custom }
nonisolated enum AssistTask: String, Codable, Sendable { case critique, plantIdeas = "plant_ideas", describe }
nonisolated enum EntitlementEnvironment: String, Codable, Sendable { case production, sandbox }
nonisolated struct AccountBalances: Codable, Equatable, Sendable {
    let production: Int
    let sandbox: Int
}
nonisolated struct AccountEntitlements: Codable, Equatable, Sendable {
    let ios: Bool
    let macos: Bool
    let bundle: Bool
}
nonisolated struct ManagedRendering: Codable, Equatable, Sendable {
    let available: Bool
    let reason: String?
}
nonisolated struct ProviderKeyMetadata: Codable, Equatable, Sendable, Identifiable {
    let provider: GatewayProvider
    let label: String?
    let fingerprint: String
    let endpointHost: String?
    let createdAt: String
    let updatedAt: String
    var id: GatewayProvider { provider }
}
nonisolated struct CreditProduct: Codable, Equatable, Sendable {
    let productId: String
    let creditMicros: Int
    let offerStartsAt: Int64?
    let offerEndsAt: Int64?
    let creditExpires: Bool?

    var offerEnd: Date? { offerEndsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    func isAvailable(at date: Date) -> Bool {
        guard productId == PurchaseCatalog.creditUSD15, creditMicros == 15_000_000, creditExpires == false,
              let start = offerStartsAt, let end = offerEndsAt, start > 0 else { return false }
        let (expectedEnd, overflow) = start.addingReportingOverflow(90 * 24 * 60 * 60 * 1000)
        let milliseconds = date.timeIntervalSince1970 * 1000
        return !overflow && end == expectedEnd && milliseconds.isFinite && milliseconds >= Double(start) && milliseconds < Double(end)
    }
}
nonisolated struct GatewayAccount: Codable, Equatable, Sendable {
    let accountId: UUID
    let balances: AccountBalances
    let entitlements: AccountEntitlements
    let entitlementEnvironment: EntitlementEnvironment
    let monthlyCapMicros: Int?
    let monthSpentMicros: Int
    let managedRender: ManagedRendering
    let sponsorshipAvailable: Bool
    let keys: [ProviderKeyMetadata]
    let creditProducts: [CreditProduct]
    let budgetAddsCredit: Bool

    func validate(accountID: UUID) throws {
        guard accountId == accountID, balances.production >= 0, balances.sandbox >= 0,
              monthSpentMicros >= 0, monthlyCapMicros.map({ (0...500_000_000).contains($0) }) ?? true,
              !budgetAddsCredit, keys.count <= 3, Set(keys.map(\.provider)).count == keys.count,
              creditProducts.count <= 100,
              Set(creditProducts.map(\.productId)).count == creditProducts.count,
              creditProducts.allSatisfy({ $0.productId.hasPrefix(PurchaseCatalog.prefix + "credit.") &&
                  $0.productId.utf8.count <= 200 && $0.creditMicros > 0 })
        else { throw GatewayError.invalidResponse }
    }
}
nonisolated struct ProviderDiscovery: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable { let imageGeneration: Bool; let text: Bool }
    let ok: Bool
    let status: Int
    let capabilities: Capabilities
    let discovery: String
    let generationVerified: Bool
    let advertisedImageModels: [String]?
    let message: String
}
nonisolated struct AssistResponse: Decodable, Sendable {
    let text: String
    let provider: GatewayProvider
    let model: String
    let providerBilling: Bool
}
nonisolated struct PurchaseAcceptance: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case granted, pendingPrerequisite = "pending_prerequisite", revoked }
    let transactionId: String
    let productId: String
    let environment: String
    let status: Status
    let creditGrantedMicros: Int
    let balances: AccountBalances
    let entitlements: AccountEntitlements
}

nonisolated struct CachedEntitlements: Codable, Sendable {
    let entitlements: AccountEntitlements
    let environment: EntitlementEnvironment
}

// Bearers never appear in descriptions, logs, project documents or UI models.
nonisolated struct StoredAccount: Codable, Sendable {
    let accountID: UUID
    let bearer: String
    var cachedEntitlements: CachedEntitlements?

    func validate() throws {
        let suffix = bearer.dropFirst(4)
        guard bearer.hasPrefix("hgs_"), suffix.utf8.count == 43,
              suffix.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw GatewayError.corruptCredentials }
    }
}

import Foundation
import Observation

nonisolated enum PurchaseState: Equatable, Sendable {
    case idle, loading, unavailable, purchasing, pending, cancelled
    case accepted, pendingPrerequisite, revoked, serverVerificationPending, failed
}

@Observable @MainActor final class PurchaseService {
    private(set) var products: [PurchaseProduct] = []
    private(set) var state: PurchaseState = .idle
    private(set) var lastError: GatewayError?
    @ObservationIgnored private let account: AccountService
    @ObservationIgnored private let store: any StorePurchaseClient
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var processing: Set<String> = []
    @ObservationIgnored private var operationInProgress = false

    init(account: AccountService, store: any StorePurchaseClient = LiveStorePurchaseClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.store = store
        self.now = now
    }

    deinit { listener?.cancel() }

    func startListening() {
        guard listener == nil else { return }
        let updates = store.updates()
        listener = Task { [weak self] in
            for await transaction in updates {
                guard !Task.isCancelled, let self else { break }
                do { try await self.accept(transaction) }
                catch { self.record(error) }
            }
        }
    }

    func stopListening() { listener?.cancel(); listener = nil }

    func loadProducts() async throws {
        try begin(); defer { operationInProgress = false }
        state = .loading; lastError = nil
        do {
            try await account.refresh()
            try await fetchProducts()
            products = availableProducts(at: now())
            guard !products.isEmpty else { throw GatewayError.productUnavailable }
            state = .idle
        } catch { products = []; record(error); throw error }
    }

    func purchase(productID: String) async throws {
        try begin(); defer { operationInProgress = false }
        lastError = nil; state = .loading
        do {
            try await account.refresh()
            guard let accountID = account.accountID else { throw GatewayError.accountRequired }
            try requirePrerequisite(productID)
            guard allowedProducts(at: now()).contains(productID), products.contains(where: { $0.id == productID }) else {
                products = availableProducts(at: now())
                throw GatewayError.productUnavailable
            }
            // Refresh StoreKit price metadata too; never charge from a stale promotional row.
            try await fetchProducts()
            guard account.accountID == accountID, allowedProducts(at: now()).contains(productID),
                  products.contains(where: { $0.id == productID }) else {
                products = availableProducts(at: now())
                throw GatewayError.productUnavailable
            }
            state = .purchasing
            switch try await store.purchase(productID: productID, accountToken: accountID) {
            case .success(let result): try await accept(result)
            case .pending: state = .pending
            case .cancelled: state = .cancelled
            }
        } catch { record(error); throw error }
    }

    func reconcileUnfinished() async throws {
        try begin(); defer { operationInProgress = false }
        guard account.accountID != nil else { throw GatewayError.accountRequired }
        try await reconcile(includeCurrent: false)
    }

    func restore() async throws {
        try begin(); defer { operationInProgress = false }
        // Never create a new account during restore, including after Keychain failures.
        try await account.refresh()
        do {
            try await store.sync()
            try await reconcile(includeCurrent: true)
            try await account.refresh()
        } catch { record(error); throw error }
    }

    private func reconcile(includeCurrent: Bool) async throws {
        let transactions = try await store.transactions(includeCurrentEntitlements: includeCurrent)
        guard transactions.count <= 1000 else { throw GatewayError.responseTooLarge }
        var firstError: (any Error)?
        var seen: Set<String> = []
        for transaction in transactions {
            if case .verified(let verified) = transaction, !seen.insert(verified.id).inserted { continue }
            do { try await accept(transaction) }
            catch { if firstError == nil { firstError = error }; record(error) }
        }
        if let firstError { throw firstError }
    }

    private func accept(_ result: StoreTransaction) async throws {
        guard case .verified(let transaction) = result else { throw GatewayError.verificationFailed }
        guard transaction.accountToken == account.accountID, account.accountID != nil else { throw GatewayError.accountMismatch }
        guard processing.insert(transaction.id).inserted else { return }
        defer { processing.remove(transaction.id) }
        // Server validates identity, product, environment and replay; no local credit arithmetic.
        let acceptance = try await account.acceptPurchase(transaction)
        try await store.finish(transactionID: transaction.id)
        switch acceptance.status {
        case .granted: state = .accepted
        case .pendingPrerequisite: state = .pendingPrerequisite
        case .revoked: state = .revoked
        }
        // A refresh failure does not undo durable acceptance or finish. Existing work stays usable.
        try await account.refresh()
    }

    func availableProducts(at date: Date) -> [PurchaseProduct] {
        let allowed = allowedProducts(at: date)
        return products.filter { allowed.contains($0.id) }
    }
    func creditOffer(productID: String, at date: Date) -> CreditProduct? {
        account.snapshot?.creditProducts.first { $0.productId == productID && $0.isAvailable(at: date) }
    }
    private func allowedProducts(at date: Date) -> Set<String> {
        guard let snapshot = account.snapshot else { return [] }
        return PurchaseCatalog.eligibleProducts(platformProducts: PurchaseCatalog.platformProducts,
            entitlements: snapshot.entitlements).union(snapshot.creditProducts.filter { $0.isAvailable(at: date) }.map(\.productId))
    }
    private func fetchProducts() async throws {
        let allowed = allowedProducts(at: now())
        let fetched = try await store.products(ids: allowed)
        guard fetched.count <= allowed.count, Set(fetched.map(\.id)).count == fetched.count,
              fetched.allSatisfy({ allowed.contains($0.id) && !$0.displayPrice.isEmpty }) else { throw GatewayError.invalidResponse }
        products = fetched.filter { PurchaseCatalog.unlocks.contains($0.id) || $0.hasApprovedCreditPrice }
    }
    private func requirePrerequisite(_ productID: String) throws {
        guard let entitlement = account.snapshot?.entitlements else { throw GatewayError.accountRequired }
        if productID == PurchaseCatalog.iosUpgrade && (!entitlement.ios || entitlement.bundle) {
            throw GatewayError.prerequisiteRequired
        }
        if productID == PurchaseCatalog.macUpgrade && (!entitlement.macos || entitlement.bundle) {
            throw GatewayError.prerequisiteRequired
        }
    }
    private func begin() throws {
        guard !operationInProgress else { throw GatewayError.busy }
        operationInProgress = true
    }
    private func record(_ error: any Error) {
        let safe = error as? GatewayError ?? .verificationFailed
        lastError = safe
        switch safe {
        case .unavailable, .productUnavailable: state = .unavailable
        case .transport, .server, .busy, .credentialSaveRequired: state = .serverVerificationPending
        default: state = .failed
        }
    }
}

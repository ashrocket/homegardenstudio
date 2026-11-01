import Foundation
import StoreKit

nonisolated enum PurchaseCatalog {
    static let prefix = "com.ashleyraiteri.homegardenstudio."
    static let creditUSD15 = prefix + "credit.usd15"
    static let ios = prefix + "unlock.ios"
    static let mac = prefix + "unlock.mac"
    static let bundle = prefix + "unlock.bundle"
    static let iosUpgrade = prefix + "upgrade.ios_to_bundle"
    static let macUpgrade = prefix + "upgrade.mac_to_bundle"
    static let unlocks: Set<String> = [ios, mac, bundle, iosUpgrade, macUpgrade]
    static var platformProducts: Set<String> {
        #if os(macOS)
        [mac, bundle, macUpgrade]
        #else
        [ios, bundle, iosUpgrade]
        #endif
    }
    static func eligibleProducts(platformProducts: Set<String>, entitlements: AccountEntitlements) -> Set<String> {
        var result = platformProducts.subtracting([iosUpgrade, macUpgrade])
        if !entitlements.bundle {
            if entitlements.ios { result.insert(iosUpgrade) }
            if entitlements.macos { result.insert(macUpgrade) }
        }
        return result
    }
}

nonisolated struct PurchaseProduct: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let displayPrice: String
    let price: Decimal?
    let currencyCode: String?
    init(id: String, name: String, detail: String, displayPrice: String, price: Decimal? = nil, currencyCode: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.displayPrice = displayPrice
        self.price = price; self.currencyCode = currencyCode
    }
    var hasApprovedCreditPrice: Bool {
        guard id == PurchaseCatalog.creditUSD15, let price, let currencyCode, !currencyCode.isEmpty, price > 0 else { return false }
        // US price is owner-approved. Other storefronts show Apple's actual localized amount.
        return currencyCode != "USD" || price == Decimal(10)
    }
}
nonisolated struct VerifiedStoreTransaction: Sendable {
    let id: String
    let productID: String
    let accountToken: UUID?
    let environment: String
    let signedJWS: String
}
nonisolated enum StoreTransaction: Sendable {
    case verified(VerifiedStoreTransaction)
    case unverified
}
nonisolated enum StorePurchaseOutcome: Sendable {
    case success(StoreTransaction), pending, cancelled
}

@MainActor protocol StorePurchaseClient {
    func products(ids: Set<String>) async throws -> [PurchaseProduct]
    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseOutcome
    func sync() async throws
    func transactions(includeCurrentEntitlements: Bool) async throws -> [StoreTransaction]
    func updates() -> AsyncStream<StoreTransaction>
    func finish(transactionID: String) async throws
}

@MainActor final class LiveStorePurchaseClient: StorePurchaseClient {
    private var loaded: [String: Product] = [:]
    private var unfinished: [String: Transaction] = [:]

    func products(ids: Set<String>) async throws -> [PurchaseProduct] {
        guard !ids.isEmpty, ids.count <= 105 else { throw GatewayError.productUnavailable }
        let products = try await Product.products(for: ids)
        loaded = Dictionary(uniqueKeysWithValues: products.filter { product in
            ids.contains(product.id) && (PurchaseCatalog.unlocks.contains(product.id)
                ? product.type == .nonConsumable : product.type == .consumable)
        }.map { ($0.id, $0) })
        return loaded.values.map { PurchaseProduct(id: $0.id, name: $0.displayName,
                                                  detail: $0.description, displayPrice: $0.displayPrice, price: $0.price, currencyCode: $0.priceFormatStyle.currencyCode) }
            .sorted { $0.id < $1.id }
    }

    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseOutcome {
        guard let product = loaded[productID] else { throw GatewayError.productUnavailable }
        switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
        case .success(let verification): return .success(try capture(verification))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw GatewayError.verificationFailed
        }
    }

    func sync() async throws { try await AppStore.sync() }

    func transactions(includeCurrentEntitlements: Bool) async throws -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.unfinished {
            guard transactions.count < 1000 else { throw GatewayError.responseTooLarge }
            transactions.append(try capture(result))
        }
        if includeCurrentEntitlements {
            for await result in Transaction.currentEntitlements {
                guard transactions.count < 1000 else { throw GatewayError.responseTooLarge }
                transactions.append(try capture(result))
            }
        }
        return transactions
    }

    func updates() -> AsyncStream<StoreTransaction> {
        AsyncStream(bufferingPolicy: .bufferingOldest(100)) { continuation in
            let task = Task { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    do { continuation.yield(try self.capture(result)) }
                    catch { continuation.yield(.unverified) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(transactionID: String) async throws {
        guard let transaction = unfinished[transactionID] else { throw GatewayError.verificationFailed }
        await transaction.finish()
        unfinished.removeValue(forKey: transactionID)
    }

    private func capture(_ result: VerificationResult<Transaction>) throws -> StoreTransaction {
        guard case .verified(let transaction) = result else { return .unverified }
        let id = String(transaction.id)
        guard unfinished[id] != nil || unfinished.count < 1000 else { throw GatewayError.responseTooLarge }
        guard result.jwsRepresentation.utf8.count <= 60_000 else { throw GatewayError.responseTooLarge }
        unfinished[id] = transaction
        return .verified(VerifiedStoreTransaction(id: id, productID: transaction.productID,
            accountToken: transaction.appAccountToken, environment: transaction.environment.rawValue,
            signedJWS: result.jwsRepresentation))
    }
}

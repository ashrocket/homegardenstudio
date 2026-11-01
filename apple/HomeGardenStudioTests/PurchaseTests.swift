import Foundation
import XCTest
@testable import HomeGardenStudio

@MainActor final class MockStorePurchaseClient: StorePurchaseClient {
    var offered: [PurchaseProduct] = []
    var outcome: StorePurchaseOutcome = .cancelled
    var transactionsToReturn: [StoreTransaction] = []
    var finished: [String] = []
    var purchases: [(String, UUID)] = []
    var syncCount = 0
    var requestedIDs: Set<String> = []
    var includedCurrent = false
    var productLoadCount = 0
    var beforeProducts: (() -> Void)?
    var beforePurchase: (() -> Void)?
    func products(ids: Set<String>) async throws -> [PurchaseProduct] { requestedIDs = ids; productLoadCount += 1; beforeProducts?(); return offered }
    func purchase(productID: String, accountToken: UUID) async throws -> StorePurchaseOutcome {
        beforePurchase?(); purchases.append((productID, accountToken)); return outcome
    }
    func sync() async throws { syncCount += 1 }
    func transactions(includeCurrentEntitlements: Bool) async throws -> [StoreTransaction] {
        includedCurrent = includeCurrentEntitlements; return transactionsToReturn
    }
    func updates() -> AsyncStream<StoreTransaction> { AsyncStream { $0.finish() } }
    func finish(transactionID: String) async throws { finished.append(transactionID) }
}

nonisolated final class PurchaseTests: XCTestCase {
    @MainActor private var platformProduct: String {
        #if os(macOS)
        PurchaseCatalog.mac
        #else
        PurchaseCatalog.ios
        #endif
    }
    @MainActor private func transaction(account: UUID? = ServiceFixture.id) -> StoreTransaction {
        .verified(.init(id: "12345", productID: platformProduct, accountToken: account,
                        environment: "Production", signedJWS: "synthetic.signed.fixture"))
    }
    @MainActor private func accepted(status: String = "granted", transactionID: String = "12345") throws -> MockGatewayTransport.Reply {
        try ServiceFixture.json(["transaction_id": transactionID, "product_id": platformProduct,
            "environment": "Production", "status": status, "credit_granted_micros": 2_000_000,
            "balances": ["production": 2_000_000, "sandbox": 0],
            "entitlements": ["ios": true, "macos": true, "bundle": false]])
    }

    @MainActor func testUnverifiedAndWrongAccountTransactionsNeverReachServerOrFinish() async throws {
        let transport = MockGatewayTransport()
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient(); let purchases = PurchaseService(account: account, store: store)
        store.transactionsToReturn = [.unverified]
        await ServiceFixture.expect(.verificationFailed) { try await purchases.reconcileUnfinished() }
        store.transactionsToReturn = [transaction(account: UUID())]
        await ServiceFixture.expect(.accountMismatch) { try await purchases.reconcileUnfinished() }
        XCTAssertTrue(store.finished.isEmpty)
        let sentRequests = await transport.requests
        XCTAssertTrue(sentRequests.isEmpty)
    }

    @MainActor func testRejectedTransactionRemainsUnfinishedAndRetryKeepsJWS() async throws {
        let transport = MockGatewayTransport([.init(status: 503, data: Data()), try accepted(), try ServiceFixture.me(unlocked: true, balance: 2_000_000)])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient(); store.transactionsToReturn = [transaction()]
        let purchases = PurchaseService(account: account, store: store)
        await ServiceFixture.expect(.server(503)) { try await purchases.reconcileUnfinished() }
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertNil(account.snapshot)
        try await purchases.reconcileUnfinished()
        XCTAssertEqual(store.finished, ["12345"])
        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(account.snapshot?.balances.production, 2_000_000)
    }

    @MainActor func testRestoreReplayDoesNotAddLifetimeCreditAgain() async throws {
        let transport = MockGatewayTransport([try ServiceFixture.me(balance: 2_000_000), try accepted(),
            try ServiceFixture.me(unlocked: true, balance: 2_000_000), try ServiceFixture.me(unlocked: true, balance: 2_000_000)])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient(); store.transactionsToReturn = [transaction(), transaction()]
        let purchases = PurchaseService(account: account, store: store)
        try await purchases.restore()
        XCTAssertEqual(store.syncCount, 1)
        XCTAssertTrue(store.includedCurrent)
        XCTAssertEqual(store.finished, ["12345"])
        XCTAssertEqual(account.snapshot?.balances.production, 2_000_000)
    }

    @MainActor func testRestoreWithoutExistingAccountDoesNotCreateOrSync() async throws {
        let transport = MockGatewayTransport()
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: MemoryAccountStore())
        try account.loadStoredAccount()
        let store = MockStorePurchaseClient(); let purchases = PurchaseService(account: account, store: store)
        await ServiceFixture.expect(.accountRequired) { try await purchases.restore() }
        XCTAssertEqual(store.syncCount, 0)
        let sentRequests = await transport.requests
        XCTAssertTrue(sentRequests.isEmpty)
    }

    @MainActor func testReceiptIdentityMismatchDoesNotFinish() async throws {
        let transport = MockGatewayTransport([try accepted(transactionID: "different")])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient(); store.transactionsToReturn = [transaction()]
        let purchases = PurchaseService(account: account, store: store)
        await ServiceFixture.expect(.invalidResponse) { try await purchases.reconcileUnfinished() }
        XCTAssertTrue(store.finished.isEmpty)
    }

    @MainActor func testDurablePendingAcceptanceFinishesWithoutUnlockOrCredit() async throws {
        let transport = MockGatewayTransport([try accepted(status: "pending_prerequisite"), try ServiceFixture.me()])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient(); store.transactionsToReturn = [transaction()]
        let purchases = PurchaseService(account: account, store: store)
        try await purchases.reconcileUnfinished()
        XCTAssertEqual(purchases.state, .pendingPrerequisite)
        XCTAssertEqual(store.finished, ["12345"])
        XCTAssertFalse(account.isUnlocked)
        XCTAssertEqual(account.snapshot?.balances.production, 0)
    }

    @MainActor func testProductsUseStorePricesAndOnlyServerConfiguredCreditIDs() async throws {
        let credit = PurchaseCatalog.creditUSD15
        let start: Int64 = 1_000_000, end: Int64 = 1_000_000 + 90 * 24 * 60 * 60 * 1000
        let transport = MockGatewayTransport([try ServiceFixture.me(credits: [["product_id": credit, "credit_micros": 15_000_000, "offer_starts_at": start, "offer_ends_at": end, "credit_expires": false]])])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient()
        store.offered = [.init(id: platformProduct, name: "Localized unlock", detail: "App Store detail", displayPrice: "€2,29")]
        let purchases = PurchaseService(account: account, store: store, now: { Date(timeIntervalSince1970: 1001) })
        try await purchases.loadProducts()
        XCTAssertEqual(purchases.products[0].displayPrice, "€2,29")
        XCTAssertEqual(store.requestedIDs, PurchaseCatalog.platformProducts.subtracting([PurchaseCatalog.iosUpgrade, PurchaseCatalog.macUpgrade]).union([credit]))
    }

    @MainActor func testActualPurchasePassesExistingAccountTokenAndWaitsForVerification() async throws {
        let transport = MockGatewayTransport([try ServiceFixture.me(), try ServiceFixture.me(), try accepted(), try ServiceFixture.me(unlocked: true, balance: 2_000_000)])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient()
        store.offered = [.init(id: platformProduct, name: "Unlock", detail: "", displayPrice: "$1.00")]
        store.outcome = .success(transaction())
        let purchases = PurchaseService(account: account, store: store)
        try await purchases.loadProducts()
        try await purchases.purchase(productID: platformProduct)
        XCTAssertEqual(store.purchases.first?.1, ServiceFixture.id)
        XCTAssertEqual(store.finished, ["12345"])
        XCTAssertTrue(account.isUnlocked)
    }

    @MainActor func testUpgradeNeedsFreshServerPrerequisite() async throws {
        #if os(macOS)
        let upgrade = PurchaseCatalog.macUpgrade
        #else
        let upgrade = PurchaseCatalog.iosUpgrade
        #endif
        let transport = MockGatewayTransport([try ServiceFixture.me(unlocked: true), try ServiceFixture.me()])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient()
        store.offered = [.init(id: upgrade, name: "Upgrade", detail: "", displayPrice: "$1.00")]
        let purchases = PurchaseService(account: account, store: store)
        try await purchases.loadProducts()
        await ServiceFixture.expect(.prerequisiteRequired) { try await purchases.purchase(productID: upgrade) }
        XCTAssertTrue(store.purchases.isEmpty)
    }

    @MainActor func testCrossPlatformUpgradeEligibilityUsesOwnedProductNotCurrentDevice() {
        let macProducts: Set<String> = [PurchaseCatalog.mac, PurchaseCatalog.bundle, PurchaseCatalog.macUpgrade]
        let iosProducts: Set<String> = [PurchaseCatalog.ios, PurchaseCatalog.bundle, PurchaseCatalog.iosUpgrade]
        let iosOwner = PurchaseCatalog.eligibleProducts(platformProducts: macProducts,
            entitlements: .init(ios: true, macos: false, bundle: false))
        XCTAssertTrue(iosOwner.contains(PurchaseCatalog.iosUpgrade)) // Approved iOS-to-bundle product, StoreKit supplies its price.
        XCTAssertFalse(iosOwner.contains(PurchaseCatalog.macUpgrade))
        let macOwner = PurchaseCatalog.eligibleProducts(platformProducts: iosProducts,
            entitlements: .init(ios: false, macos: true, bundle: false))
        XCTAssertTrue(macOwner.contains(PurchaseCatalog.macUpgrade))
        XCTAssertFalse(macOwner.contains(PurchaseCatalog.iosUpgrade))
        let bundleOwner = PurchaseCatalog.eligibleProducts(platformProducts: macProducts,
            entitlements: .init(ios: true, macos: true, bundle: true))
        XCTAssertFalse(bundleOwner.contains(PurchaseCatalog.iosUpgrade))
        XCTAssertFalse(bundleOwner.contains(PurchaseCatalog.macUpgrade))
    }

    @MainActor func testCrossPlatformOwnerLoadsOwnedPlatformUpgradeWithStorePrice() async throws {
        #if os(macOS)
        let upgrade = PurchaseCatalog.iosUpgrade
        let reply = try ServiceFixture.me(ios: true, macos: false)
        let storePrice = "$3.00"
        #else
        let upgrade = PurchaseCatalog.macUpgrade
        let reply = try ServiceFixture.me(ios: false, macos: true)
        let storePrice = "$0.99"
        #endif
        let transport = MockGatewayTransport([reply])
        let account = try ServiceFixture.account(transport)
        let store = MockStorePurchaseClient()
        store.offered = [.init(id: upgrade, name: "Owned platform upgrade", detail: "", displayPrice: storePrice)]
        let purchases = PurchaseService(account: account, store: store)
        try await purchases.loadProducts()
        XCTAssertTrue(store.requestedIDs.contains(upgrade))
        XCTAssertEqual(purchases.products.first?.id, upgrade)
        XCTAssertEqual(purchases.products.first?.displayPrice, storePrice)
    }
}

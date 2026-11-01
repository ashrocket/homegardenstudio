import Foundation
import XCTest
@testable import HomeGardenStudio

nonisolated final class CreditPromotionTests: XCTestCase {
    private let start: Int64 = 1_000_000 // Synthetic test epoch; not an activation date.
    private var end: Int64 { start + 90 * 24 * 60 * 60 * 1000 }
    private var during: Date { Date(timeIntervalSince1970: Double(start + 1000) / 1000) }
    private var after: Date { Date(timeIntervalSince1970: Double(end) / 1000) }
    private var product: PurchaseProduct { .init(id: PurchaseCatalog.creditUSD15, name: "Credit fixture", detail: "Synthetic test", displayPrice: "$10.00", price: 10, currencyCode: "USD") }
    private var offer: [String: Any] { ["product_id": PurchaseCatalog.creditUSD15, "credit_micros": 15_000_000, "offer_starts_at": start, "offer_ends_at": end, "credit_expires": false] }
    private func decoded(_ fields: [String: Any]) throws -> CreditProduct {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CreditProduct.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func testOfferWindowBoundariesAndNonexpiryTerms() throws {
        let value = try decoded(offer)
        XCTAssertTrue(value.isAvailable(at: Date(timeIntervalSince1970: Double(start) / 1000)))
        XCTAssertTrue(value.isAvailable(at: during))
        XCTAssertFalse(value.isAvailable(at: Date(timeIntervalSince1970: Double(start - 1) / 1000)))
        XCTAssertFalse(value.isAvailable(at: after))
        XCTAssertEqual(value.creditExpires, false)
        XCTAssertEqual(value.offerEnd, after)
    }
    func testUnsetOrChangedPromotionTermsStayHidden() throws {
        for key in ["offer_starts_at", "offer_ends_at", "credit_expires"] {
            var missing = offer; missing.removeValue(forKey: key)
            XCTAssertFalse(try decoded(missing).isAvailable(at: during))
        }
        for (key, value): (String, Any) in [("credit_expires", true), ("credit_micros", 16_000_000), ("product_id", "unapproved.credit"), ("offer_ends_at", end + 1), ("offer_starts_at", Int64.max)] {
            var changed = offer; changed[key] = value
            XCTAssertFalse(try decoded(changed).isAvailable(at: during))
        }
    }
    func testUSDOfferRequiresApprovedNumericStoreKitPrice() {
        XCTAssertTrue(product.hasApprovedCreditPrice)
        XCTAssertFalse(PurchaseProduct(id: PurchaseCatalog.creditUSD15, name: "", detail: "", displayPrice: "$10.99", price: Decimal(string: "10.99"), currencyCode: "USD").hasApprovedCreditPrice)
        XCTAssertFalse(PurchaseProduct(id: PurchaseCatalog.creditUSD15, name: "", detail: "", displayPrice: "$10.00").hasApprovedCreditPrice)
        XCTAssertTrue(PurchaseProduct(id: PurchaseCatalog.creditUSD15, name: "", detail: "", displayPrice: "€10,99", price: Decimal(string: "10.99"), currencyCode: "EUR").hasApprovedCreditPrice)
    }
    @MainActor func testExpiredCachedOfferHidesAndFreshAccountBlocksCheckout() async throws {
        let clock = PromotionClock(during)
        let transport = MockGatewayTransport([try ServiceFixture.me(credits: [offer]), try ServiceFixture.me()])
        let account = try ServiceFixture.account(transport), store = MockStorePurchaseClient()
        store.offered = [product]
        let purchases = PurchaseService(account: account, store: store, now: { clock.read() })
        try await purchases.loadProducts()
        XCTAssertEqual(purchases.availableProducts(at: during).map(\.id), [PurchaseCatalog.creditUSD15])
        XCTAssertNotNil(purchases.creditOffer(productID: PurchaseCatalog.creditUSD15, at: during))
        XCTAssertTrue(purchases.availableProducts(at: after).isEmpty)
        clock.set(after)
        await ServiceFixture.expect(.productUnavailable) { try await purchases.purchase(productID: PurchaseCatalog.creditUSD15) }
        XCTAssertTrue(store.purchases.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2) // Catalog refresh occurs before any StoreKit checkout.
    }
    @MainActor func testExpiryDuringStoreKitRefreshBlocksCheckout() async throws {
        let clock = PromotionClock(during), endDate = after
        let transport = MockGatewayTransport([try ServiceFixture.me(credits: [offer]), try ServiceFixture.me(credits: [offer])])
        let account = try ServiceFixture.account(transport), store = MockStorePurchaseClient()
        store.offered = [product]
        let purchases = PurchaseService(account: account, store: store, now: { clock.read() })
        try await purchases.loadProducts()
        store.beforeProducts = { clock.set(endDate) }
        await ServiceFixture.expect(.productUnavailable) { try await purchases.purchase(productID: PurchaseCatalog.creditUSD15) }
        XCTAssertEqual(store.productLoadCount, 2)
        XCTAssertTrue(store.purchases.isEmpty)
    }
    @MainActor func testChangedUSDPriceBlocksCheckoutAfterFreshStoreKitMetadata() async throws {
        let date = during
        let transport = MockGatewayTransport([try ServiceFixture.me(credits: [offer]), try ServiceFixture.me(credits: [offer])])
        let account = try ServiceFixture.account(transport), store = MockStorePurchaseClient()
        store.offered = [product]
        let purchases = PurchaseService(account: account, store: store, now: { date })
        try await purchases.loadProducts()
        store.offered = [.init(id: PurchaseCatalog.creditUSD15, name: "Changed", detail: "", displayPrice: "$11.00", price: 11, currencyCode: "USD")]
        await ServiceFixture.expect(.productUnavailable) { try await purchases.purchase(productID: PurchaseCatalog.creditUSD15) }
        XCTAssertTrue(store.purchases.isEmpty)
        XCTAssertTrue(purchases.products.isEmpty)
    }
    @MainActor func testAcceptedCheckoutMayCompleteAfterWindowEnds() async throws {
        let clock = PromotionClock(during), endDate = after
        let transport = MockGatewayTransport([try ServiceFixture.me(credits: [offer]), try ServiceFixture.me(credits: [offer]), try acceptance(), try ServiceFixture.me(balance: 15_000_000)])
        let account = try ServiceFixture.account(transport), store = MockStorePurchaseClient()
        store.offered = [product]; store.outcome = .success(transaction)
        store.beforePurchase = { clock.set(endDate) }
        let purchases = PurchaseService(account: account, store: store, now: { clock.read() })
        try await purchases.loadProducts(); try await purchases.purchase(productID: PurchaseCatalog.creditUSD15)
        XCTAssertEqual(store.finished, ["credit-fixture"])
        XCTAssertEqual(account.snapshot?.balances.production, 15_000_000)
        XCTAssertEqual(purchases.state, .accepted)
    }
    @MainActor func testUnfinishedAndRestoreReplayContinueWithoutLiveOffer() async throws {
        let date = after
        let transport = MockGatewayTransport([.init(status: 503, data: Data()), try acceptance(), try ServiceFixture.me(balance: 15_000_000),
            try ServiceFixture.me(balance: 15_000_000), try acceptance(), try ServiceFixture.me(balance: 15_000_000), try ServiceFixture.me(balance: 15_000_000)])
        let account = try ServiceFixture.account(transport), store = MockStorePurchaseClient()
        store.transactionsToReturn = [transaction]
        let purchases = PurchaseService(account: account, store: store, now: { date })
        await ServiceFixture.expect(.server(503)) { try await purchases.reconcileUnfinished() }
        XCTAssertTrue(store.finished.isEmpty)
        try await purchases.reconcileUnfinished()
        try await purchases.restore()
        XCTAssertEqual(store.finished, ["credit-fixture", "credit-fixture"])
        XCTAssertEqual(account.snapshot?.balances.production, 15_000_000)
        XCTAssertTrue(store.requestedIDs.isEmpty)
        XCTAssertTrue(store.purchases.isEmpty)
    }
    @MainActor private var transaction: StoreTransaction {
        .verified(.init(id: "credit-fixture", productID: PurchaseCatalog.creditUSD15, accountToken: ServiceFixture.id, environment: "Production", signedJWS: "synthetic.credit.fixture"))
    }
    @MainActor private func acceptance() throws -> MockGatewayTransport.Reply {
        try ServiceFixture.json(["transaction_id": "credit-fixture", "product_id": PurchaseCatalog.creditUSD15, "environment": "Production", "status": "granted", "credit_granted_micros": 15_000_000,
            "balances": ["production": 15_000_000, "sandbox": 0], "entitlements": ["ios": false, "macos": false, "bundle": false]])
    }
}

nonisolated private final class PromotionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

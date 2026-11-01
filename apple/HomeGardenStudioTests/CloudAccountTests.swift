import Foundation
import XCTest
@testable import HomeGardenStudio

actor MockGatewayTransport: GatewayTransport {
    struct Reply: Sendable {
        let status: Int
        let data: Data
        var url: URL? = nil
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply] = []) { self.replies = replies }
    func append(_ reply: Reply) { replies.append(reply) }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw GatewayError.transport }
        let reply = replies.removeFirst()
        return GatewayHTTPResponse(status: reply.status, url: reply.url ?? request.url!, data: reply.data)
    }
}

@MainActor final class MemoryAccountStore: AccountCredentialStore {
    var values: [String: StoredAccount] = [:]
    var failLoad = false
    var failSave = false
    var failDelete = false
    func load(origin: String) throws -> StoredAccount? {
        if failLoad { throw GatewayError.credentialsUnavailable }
        return values[origin]
    }
    func save(_ account: StoredAccount, origin: String) throws {
        if failSave { throw GatewayError.credentialsUnavailable }
        values[origin] = account
    }
    func delete(origin: String) throws {
        if failDelete { throw GatewayError.credentialsUnavailable }
        values.removeValue(forKey: origin)
    }
}

@MainActor enum ServiceFixture {
    static let origin = "https://gateway.example.test"
    static let id = UUID(uuidString: "19B2A59D-3B36-4BF9-94F4-2724F58DAB90")!
    static let bearer = "hgs_" + String(repeating: "a", count: 43)
    static func json(_ value: [String: Any], status: Int = 200) throws -> MockGatewayTransport.Reply {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: value))
    }
    static func me(unlocked: Bool = false, balance: Int = 0, environment: String = "production",
                   credits: [[String: Any]] = []) throws -> MockGatewayTransport.Reply {
        try json(["account_id": id.uuidString, "balances": ["production": balance, "sandbox": 0],
                  "entitlements": ["ios": unlocked, "macos": unlocked, "bundle": false],
                  "entitlement_environment": environment, "monthly_cap_micros": NSNull(),
                  "month_spent_micros": 0, "managed_render": ["available": false, "reason": "disabled"],
                  "sponsorship_available": false, "keys": [], "credit_products": credits,
                  "budget_adds_credit": false])
    }
    static func account(_ transport: MockGatewayTransport, store: MemoryAccountStore = MemoryAccountStore(),
                        cached: Bool = false) throws -> AccountService {
        store.values[origin] = StoredAccount(accountID: id, bearer: bearer,
            cachedEntitlements: cached ? CachedEntitlements(entitlements: .init(ios: true, macos: true, bundle: false),
                                                           environment: .production) : nil)
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: origin), transport: transport), credentials: store)
        try account.loadStoredAccount()
        return account
    }
    static func expect(_ expected: GatewayError, _ operation: () async throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected a failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? GatewayError, expected, file: file, line: line) }
    }
}

nonisolated final class CloudAccountTests: XCTestCase {
    @MainActor func testMissingGatewayAndInvalidOriginsFailClosed() async throws {
        XCTAssertThrowsError(try GatewayClient(baseURL: nil))
        for string in ["http://gateway.example.test", "https://user:secret@gateway.example.test", "https://gateway.example.test/path", "https://gateway.example.test?other=1"] {
            XCTAssertThrowsError(try GatewayClient(baseURL: URL(string: string)))
        }
        let account = AccountService(client: nil, credentials: MemoryAccountStore())
        XCTAssertEqual(account.state, .unavailable)
        await ServiceFixture.expect(.unavailable) { try await account.createAccount() }
        XCTAssertFalse(account.isUnlocked)
    }

    @MainActor func testKeychainReadFailureNeverCreatesAccount() async throws {
        let store = MemoryAccountStore(); store.failLoad = true
        let transport = MockGatewayTransport()
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: store)
        XCTAssertThrowsError(try account.loadStoredAccount())
        await ServiceFixture.expect(.credentialsUnavailable) { try await account.createAccount() }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testCorruptBearerAndExistingAccountCannotBeReplaced() async throws {
        let store = MemoryAccountStore()
        store.values[ServiceFixture.origin] = StoredAccount(accountID: ServiceFixture.id, bearer: "invalid")
        let transport = MockGatewayTransport()
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: store)
        XCTAssertThrowsError(try account.loadStoredAccount())
        await ServiceFixture.expect(.credentialsUnavailable) { try await account.createAccount() }
        XCTAssertEqual(store.values[ServiceFixture.origin]?.bearer, "invalid")
        let sentRequests = await transport.requests
        XCTAssertTrue(sentRequests.isEmpty)
    }

    @MainActor func testCreatedCredentialSaveFailureIsRetryableWithoutAnotherAccount() async throws {
        let store = MemoryAccountStore(); store.failSave = true
        let transport = MockGatewayTransport([try ServiceFixture.json(["account_id": ServiceFixture.id.uuidString, "secret": ServiceFixture.bearer], status: 201)])
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: store)
        await ServiceFixture.expect(.credentialSaveRequired) { try await account.createAccount() }
        XCTAssertEqual(account.accountID, ServiceFixture.id)
        await ServiceFixture.expect(.accountExists) { try await account.createAccount() }
        store.failSave = false
        try account.retryCredentialSave()
        XCTAssertEqual(store.values[ServiceFixture.origin]?.accountID, ServiceFixture.id)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor func testOfflineCacheAndServerRevocation() async throws {
        let transport = MockGatewayTransport()
        let store = MemoryAccountStore()
        let account = try ServiceFixture.account(transport, store: store, cached: true)
        await ServiceFixture.expect(.transport) { try await account.refresh() }
        XCTAssertTrue(account.isUnlocked)
        XCTAssertEqual(account.state, .offline)
        await transport.append(try ServiceFixture.me())
        try await account.refresh()
        XCTAssertFalse(account.isUnlocked)
        XCTAssertEqual(store.values[ServiceFixture.origin]?.cachedEntitlements?.entitlements.macos, false)
    }

    @MainActor func testProviderConfirmationPrecedesAnyTransmission() async throws {
        let transport = MockGatewayTransport()
        let account = try ServiceFixture.account(transport)
        await ServiceFixture.expect(.confirmationRequired) {
            try await account.saveProvider(.openai, secret: "sk-" + String(repeating: "x", count: 30), confirmedProvider: .anthropic)
        }
        let sentRequests = await transport.requests
        XCTAssertTrue(sentRequests.isEmpty)
    }

    @MainActor func testUnauthorizedBearerIsPreservedAndCannotTriggerReplacementAccount() async throws {
        let transport = MockGatewayTransport([.init(status: 401, data: Data())])
        let store = MemoryAccountStore()
        let account = try ServiceFixture.account(transport, store: store, cached: true)
        await ServiceFixture.expect(.unauthorized) { try await account.refresh() }
        XCTAssertEqual(account.state, .recoveryRequired)
        XCTAssertEqual(store.values[ServiceFixture.origin]?.bearer, ServiceFixture.bearer)
        XCTAssertTrue(account.isUnlocked)
        await ServiceFixture.expect(.accountExists) { try await account.createAccount() }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor func testDiscoveryCannotPromoteGenerationCapability() async throws {
        let response = try ServiceFixture.json(["ok": true, "status": 200,
            "capabilities": ["image_generation": true, "text": false],
            "discovery": "available", "generation_verified": false, "message": "Synthetic discovery"])
        let transport = MockGatewayTransport([response])
        let account = try ServiceFixture.account(transport)
        await ServiceFixture.expect(.invalidResponse) { _ = try await account.testProvider(.openai) }
    }

    @MainActor func testRedirectAndForeignResponseCannotBeAccepted() async throws {
        let transport = MockGatewayTransport([.init(status: 302, data: Data()),
            .init(status: 200, data: Data("{}".utf8), url: URL(string: "https://other.example.test/v1/me"))])
        let account = try ServiceFixture.account(transport)
        await ServiceFixture.expect(.server(302)) { try await account.refresh() }
        await ServiceFixture.expect(.invalidResponse) { try await account.refresh() }
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "gateway.example.test" })
    }

    @MainActor func testRequestAndResponseBounds() async throws {
        let transport = MockGatewayTransport([.init(status: 200, data: Data(repeating: 32, count: 262_145))])
        let account = try ServiceFixture.account(transport)
        await ServiceFixture.expect(.invalidInput) {
            let _: GatewayAccount = try await account.authenticatedRequest("POST", path: "/v1/me", body: Data(repeating: 32, count: 65_537))
        }
        await ServiceFixture.expect(.invalidResponse) { try await account.refresh() }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor func testBudgetClearEncodesExplicitNullWithoutAddingCredit() async throws {
        let transport = MockGatewayTransport([try ServiceFixture.json(["monthly_cap_micros": NSNull(), "budget_adds_credit": false]), try ServiceFixture.me(balance: 13)])
        let account = try ServiceFixture.account(transport)
        try await account.setBudget(micros: nil)
        let request = await transport.requests[0]
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertTrue(body["monthly_cap_micros"] is NSNull)
        XCTAssertEqual(account.snapshot?.balances.production, 13)
    }

    @MainActor func testDeletionKeepsCredentialUntilServerSuccessAndLocalRetry() async throws {
        let transport = MockGatewayTransport([.init(status: 503, data: Data()), .init(status: 204, data: Data())])
        let store = MemoryAccountStore()
        let account = try ServiceFixture.account(transport, store: store, cached: true)
        await ServiceFixture.expect(.server(503)) { try await account.deleteAccount(confirmed: true) }
        XCTAssertNotNil(store.values[ServiceFixture.origin])
        store.failDelete = true
        await ServiceFixture.expect(.credentialsUnavailable) { try await account.deleteAccount(confirmed: true) }
        XCTAssertEqual(account.state, .deletionPending)
        XCTAssertFalse(account.isUnlocked)
        store.failDelete = false
        try await account.deleteAccount(confirmed: true)
        XCTAssertNil(account.accountID)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor func testEnvironmentSelectorPinsVerifiedOriginAndRejectsUnknownOrSharedConfiguration() async throws {
        struct Environment: AppEnvironmentClient {
            let value: EntitlementEnvironment?
            func verifiedEnvironment() async throws -> EntitlementEnvironment {
                guard let value else { throw GatewayError.verificationFailed }; return value
            }
        }
        let production = URL(string: "https://production.example.test")!
        let sandbox = URL(string: "https://sandbox.example.test")!
        let selection = try await GatewayEnvironmentSelector.select(productionURL: production, sandboxURL: sandbox, environment: Environment(value: .sandbox))
        XCTAssertEqual(selection.client.origin, sandbox.absoluteString)
        XCTAssertEqual(selection.client.expectedEnvironment, .sandbox)
        await ServiceFixture.expect(.verificationFailed) {
            _ = try await GatewayEnvironmentSelector.select(productionURL: production, sandboxURL: sandbox, environment: Environment(value: nil))
        }
        await ServiceFixture.expect(.invalidConfiguration) {
            _ = try await GatewayEnvironmentSelector.select(productionURL: production, sandboxURL: production, environment: Environment(value: .production))
        }
        await ServiceFixture.expect(.unavailable) {
            _ = try await GatewayEnvironmentSelector.select(productionURL: production, sandboxURL: nil, environment: Environment(value: .sandbox))
        }
    }

    @MainActor func testServerEnvironmentCannotOverrideVerifiedAppEnvironment() async throws {
        let transport = MockGatewayTransport([try ServiceFixture.me(environment: "sandbox")])
        let store = MemoryAccountStore()
        store.values[ServiceFixture.origin] = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport, expectedEnvironment: .production), credentials: store)
        try account.loadStoredAccount()
        await ServiceFixture.expect(.invalidResponse) { try await account.refresh() }
        XCTAssertNil(account.snapshot)
    }
}

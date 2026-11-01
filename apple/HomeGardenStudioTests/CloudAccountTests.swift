import Foundation
import Security
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

// Models Security's primary-key uniqueness separately from generic-attribute matching.
// Every operation invokes the actual KeychainAccountStore query construction, never the OS.
@MainActor final class MockKeychainSecurityClient: KeychainSecurityClient {
    var items: [String: [String: Any]] = [:]
    var beforeAdd: (() -> Void)?
    var beforeUpdate: (() -> Void)?
    private(set) var updates: [[String: Any]] = []
    private(set) var deletes: [[String: Any]] = []

    private func primary(_ q: [String: Any]) -> String {
        [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup].map { String(describing: q[$0 as String]!) }.joined(separator: "|")
    }
    private func matches(_ item: [String: Any], _ q: [String: Any]) -> Bool {
        for key in [kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup] {
            if let expected = q[key as String], String(describing: item[key as String]!) != String(describing: expected) { return false }
        }
        guard let marker = q[kSecAttrGeneric as String] as? Data else { return true }
        return item[kSecAttrGeneric as String] as? Data == marker
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        if let maximum = query[kSecMatchLimit as String] as? Int {
            let matching = items.values.filter { matches($0, query) }.prefix(maximum).map { item in
                var attributes = item
                if query[kSecReturnData as String] as? Bool != true { attributes.removeValue(forKey: kSecValueData as String) }
                return attributes
            }
            return matching.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, matching as CFArray)
        }
        guard let item = items[primary(query)], matches(item, query) else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        let hook = beforeAdd; beforeAdd = nil; hook?()
        let key = primary(attributes)
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = attributes
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let hook = beforeUpdate; beforeUpdate = nil; hook?()
        updates.append(query)
        let key = primary(query)
        guard var item = items[key], matches(item, query) else { return errSecItemNotFound }
        attributes.forEach { item[$0.key] = $0.value }
        items[key] = item
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deletes.append(query)
        let key = primary(query)
        guard let item = items[key], matches(item, query) else { return errSecItemNotFound }
        items.removeValue(forKey: key)
        return errSecSuccess
    }
}

nonisolated struct InterleavingAccountTransport: GatewayTransport {
    let response: Data
    let beforeResponse: @MainActor @Sendable () throws -> Void
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> GatewayHTTPResponse {
        try await beforeResponse()
        return GatewayHTTPResponse(status: 201, url: request.url!, data: response)
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
                   credits: [[String: Any]] = [], ios: Bool? = nil, macos: Bool? = nil) throws -> MockGatewayTransport.Reply {
        try json(["account_id": id.uuidString, "balances": ["production": balance, "sandbox": 0],
                  "entitlements": ["ios": ios ?? unlocked, "macos": macos ?? unlocked, "bundle": false],
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

    @MainActor func testKeychainCrossAccountCollisionPreservesIdentityAndSameAccountCacheUpdate() throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let original = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        try store.save(original, origin: ServiceFixture.origin)
        let other = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "b", count: 43))
        XCTAssertThrowsError(try store.save(other, origin: ServiceFixture.origin)) {
            XCTAssertEqual($0 as? GatewayError, .credentialConflict)
        }
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.accountID, original.accountID)
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.bearer, original.bearer)
        var updated = original
        updated.cachedEntitlements = .init(entitlements: .init(ios: true, macos: true, bundle: false), environment: .production)
        try store.save(updated, origin: ServiceFixture.origin)
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.cachedEntitlements?.entitlements.macos, true)
        XCTAssertTrue(security.updates.allSatisfy { $0[kSecAttrGeneric as String] is Data })
    }

    @MainActor func testKeychainInsertInterleavingCannotReplaceWinner() throws {
        let security = MockKeychainSecurityClient()
        let first = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let second = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let winner = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        let loser = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "b", count: 43))
        XCTAssertNil(try first.load(origin: ServiceFixture.origin))
        XCTAssertNil(try second.load(origin: ServiceFixture.origin))
        security.beforeAdd = {
            do { try first.save(winner, origin: ServiceFixture.origin) }
            catch { XCTFail("The competing insertion must succeed") }
        }
        XCTAssertThrowsError(try second.save(loser, origin: ServiceFixture.origin)) {
            XCTAssertEqual($0 as? GatewayError, .credentialConflict)
        }
        XCTAssertEqual(try first.load(origin: ServiceFixture.origin)?.accountID, winner.accountID)
        XCTAssertEqual(security.items.count, 3) // Active winner plus both immutable recovery records.
        XCTAssertEqual(Set(try first.recoverableAccounts(origin: ServiceFixture.origin).map(\.id)), [winner.accountID, loser.accountID])
    }

    @MainActor func testStaleKeychainWriteAndDeleteCannotAffectReplacementIdentity() throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let stale = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        let current = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "c", count: 43))
        try store.save(stale, origin: ServiceFixture.origin)
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.accountID, stale.accountID)
        let synchronized = MockKeychainSecurityClient()
        let synchronizedStore = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: synchronized)
        try synchronizedStore.save(current, origin: ServiceFixture.origin)
        security.beforeUpdate = { security.items.merge(synchronized.items) { _, incoming in incoming } }
        XCTAssertThrowsError(try store.save(stale, origin: ServiceFixture.origin))
        try store.delete(origin: ServiceFixture.origin, accountID: stale.accountID)
        XCTAssertThrowsError(try store.delete(origin: ServiceFixture.origin))
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.accountID, current.accountID)
        XCTAssertTrue(security.deletes.allSatisfy { $0[kSecAttrGeneric as String] is Data })
        try store.delete(origin: ServiceFixture.origin, accountID: current.accountID)
        XCTAssertNil(try store.load(origin: ServiceFixture.origin))
    }

    @MainActor func testUnmarkedOrMismatchedKeychainDataIsPreservedWithoutMigration() throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let account = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        try store.save(account, origin: ServiceFixture.origin)
        let key = try XCTUnwrap(security.items.first { $0.value[kSecAttrAccount as String] as? String == ServiceFixture.origin }?.key)
        security.items[key]?[kSecAttrGeneric as String] = nil
        let data = security.items[key]?[kSecValueData as String] as? Data
        XCTAssertThrowsError(try store.load(origin: ServiceFixture.origin))
        XCTAssertThrowsError(try store.save(account, origin: ServiceFixture.origin))
        XCTAssertEqual(security.items[key]?[kSecValueData as String] as? Data, data)
        security.items[key]?[kSecAttrGeneric as String] = Data(UUID().uuidString.utf8)
        XCTAssertThrowsError(try store.load(origin: ServiceFixture.origin))
        XCTAssertEqual(security.items[key]?[kSecValueData as String] as? Data, data)
    }

    @MainActor func testAccountCreationCollisionRecoversWinnerWithoutAnotherRequest() async throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let otherDevice = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let winner = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer,
            cachedEntitlements: .init(entitlements: .init(ios: true, macos: true, bundle: true), environment: .production))
        let candidateID = UUID()
        let reply = try ServiceFixture.json(["account_id": candidateID.uuidString, "secret": "hgs_" + String(repeating: "b", count: 43)])
        var requests = 0
        let transport = InterleavingAccountTransport(response: reply.data) {
            requests += 1
            try otherDevice.save(winner, origin: ServiceFixture.origin)
        }
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: store)
        await ServiceFixture.expect(.credentialConflict) { try await account.createAccount() }
        XCTAssertEqual(account.state, .credentialConflict)
        XCTAssertEqual(account.accountID, candidateID)
        await ServiceFixture.expect(.credentialConflict) { try await account.refresh() }
        await ServiceFixture.expect(.accountExists) { try await account.createAccount() }
        try account.recoverStoredAccount()
        XCTAssertEqual(account.accountID, winner.accountID)
        XCTAssertTrue(account.isUnlocked)
        XCTAssertEqual(account.state, .offline)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.bearer, winner.bearer)
        XCTAssertEqual(Set(try account.recoverableAccounts().map(\.id)), [winner.accountID, candidateID])
        try account.recoverStoredAccount(accountID: candidateID)
        XCTAssertEqual(account.accountID, candidateID)
        XCTAssertFalse(account.isUnlocked)
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testUnsynchronizedDevicesRetainBothRecoveryRecordsAfterActiveWinnerReplacement() throws {
        let deviceA = MockKeychainSecurityClient()
        let deviceB = MockKeychainSecurityClient()
        let storeA = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: deviceA)
        let storeB = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: deviceB)
        let accountA = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer,
            cachedEntitlements: .init(entitlements: .init(ios: true, macos: true, bundle: true), environment: .production))
        let accountB = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "b", count: 43))
        try storeA.save(accountA, origin: ServiceFixture.origin)
        try storeB.save(accountB, origin: ServiceFixture.origin)
        // Model iCloud choosing B for the conflicting active item; UUID recovery primary keys differ.
        deviceA.items.merge(deviceB.items) { _, incoming in incoming }
        XCTAssertEqual(try storeA.load(origin: ServiceFixture.origin)?.accountID, accountB.accountID)
        XCTAssertEqual(Set(try storeA.recoverableAccounts(origin: ServiceFixture.origin).map(\.id)), [accountA.accountID, accountB.accountID])
        let selectedA = try storeA.selectAccount(origin: ServiceFixture.origin, accountID: accountA.accountID)
        XCTAssertEqual(selectedA.bearer, accountA.bearer)
        XCTAssertNil(selectedA.cachedEntitlements) // Immutable recovery cannot resurrect old cached access.
        let selectedB = try storeA.selectAccount(origin: ServiceFixture.origin, accountID: accountB.accountID)
        XCTAssertEqual(selectedB.bearer, accountB.bearer)
        try storeA.delete(origin: ServiceFixture.origin, accountID: accountA.accountID)
        XCTAssertEqual(try storeA.load(origin: ServiceFixture.origin)?.accountID, accountB.accountID)
        XCTAssertEqual(try storeA.recoverableAccounts(origin: ServiceFixture.origin).map(\.id), [accountB.accountID])
    }

    @MainActor func testRecoverySelectionCompareAndSetPreservesConcurrentWinnerAndRecords() throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let a = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        let b = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "b", count: 43))
        let c = StoredAccount(accountID: UUID(), bearer: "hgs_" + String(repeating: "c", count: 43))
        try store.save(a, origin: ServiceFixture.origin)
        XCTAssertThrowsError(try store.save(b, origin: ServiceFixture.origin))
        XCTAssertThrowsError(try store.save(c, origin: ServiceFixture.origin))
        security.beforeUpdate = {
            do { _ = try store.selectAccount(origin: ServiceFixture.origin, accountID: c.accountID) }
            catch { XCTFail("The competing selection must succeed") }
        }
        XCTAssertThrowsError(try store.selectAccount(origin: ServiceFixture.origin, accountID: b.accountID)) {
            XCTAssertEqual($0 as? GatewayError, .credentialConflict)
        }
        XCTAssertEqual(try store.load(origin: ServiceFixture.origin)?.accountID, c.accountID)
        XCTAssertEqual(try store.recoverableAccounts(origin: ServiceFixture.origin).count, 3)
    }

    @MainActor func testRecoveryRecordsAreImmutableOriginBoundAndBounded() throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        let original = StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer)
        try store.save(original, origin: ServiceFixture.origin)
        let changedBearer = StoredAccount(accountID: original.accountID, bearer: "hgs_" + String(repeating: "c", count: 43))
        XCTAssertThrowsError(try store.save(changedBearer, origin: ServiceFixture.origin))
        XCTAssertEqual(try store.selectAccount(origin: ServiceFixture.origin, accountID: original.accountID).bearer, original.bearer)
        XCTAssertTrue(try store.recoverableAccounts(origin: "https://other.example.test").isEmpty)
        for _ in 1..<KeychainAccountStore.maximumRecoveryAccounts {
            let another = StoredAccount(accountID: UUID(), bearer: ServiceFixture.bearer)
            XCTAssertThrowsError(try store.save(another, origin: ServiceFixture.origin))
        }
        let overflow = StoredAccount(accountID: UUID(), bearer: ServiceFixture.bearer)
        XCTAssertThrowsError(try store.save(overflow, origin: ServiceFixture.origin))
        XCTAssertEqual(try store.recoverableAccounts(origin: ServiceFixture.origin).count, 32)
        XCTAssertThrowsError(try store.selectAccount(origin: ServiceFixture.origin, accountID: overflow.accountID))
    }

    @MainActor func testMissingActivePointerRequiresRecoveryInsteadOfCreatingAnotherAccount() async throws {
        let security = MockKeychainSecurityClient()
        let store = try KeychainAccountStore(accessGroup: "SYNTHETIC.shared", security: security)
        try store.save(StoredAccount(accountID: ServiceFixture.id, bearer: ServiceFixture.bearer), origin: ServiceFixture.origin)
        let key = try XCTUnwrap(security.items.first { $0.value[kSecAttrAccount as String] as? String == ServiceFixture.origin }?.key)
        security.items.removeValue(forKey: key)
        let transport = MockGatewayTransport()
        let account = AccountService(client: try GatewayClient(baseURL: URL(string: ServiceFixture.origin), transport: transport), credentials: store)
        await ServiceFixture.expect(.credentialConflict) { try await account.createAccount() }
        XCTAssertEqual(account.state, .credentialConflict)
        try account.recoverStoredAccount(accountID: ServiceFixture.id)
        XCTAssertEqual(account.accountID, ServiceFixture.id)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testFailedRecoverySelectionKeepsPriorIdentityAndBlocksCloud() async throws {
        let transport = MockGatewayTransport()
        let account = try ServiceFixture.account(transport, cached: true)
        XCTAssertThrowsError(try account.recoverStoredAccount(accountID: UUID()))
        XCTAssertEqual(account.state, .credentialConflict)
        XCTAssertEqual(account.accountID, ServiceFixture.id)
        XCTAssertTrue(account.isUnlocked)
        await ServiceFixture.expect(.credentialConflict) { try await account.refresh() }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testDeletionCleanupFailureRetainsIdentityAndRetriesBeforeKeychainRemoval() async throws {
        let transport = MockGatewayTransport([.init(status: 204, data: Data())])
        let store = MemoryAccountStore()
        let account = try ServiceFixture.account(transport, store: store, cached: true)
        var attempts = 0
        await ServiceFixture.expect(.credentialsUnavailable) {
            try await account.deleteAccount(confirmed: true) { origin, id in
                XCTAssertEqual(origin, ServiceFixture.origin)
                XCTAssertEqual(id, ServiceFixture.id)
                XCTAssertNotNil(store.values[origin])
                attempts += 1
                throw GatewayError.credentialsUnavailable
            }
        }
        XCTAssertEqual(account.state, .deletionPending)
        XCTAssertEqual(account.accountID, ServiceFixture.id)
        XCTAssertNotNil(store.values[ServiceFixture.origin])
        XCTAssertThrowsError(try account.recoverStoredAccount(accountID: ServiceFixture.id))
        try await account.deleteAccount(confirmed: true) { origin, id in
            XCTAssertEqual(id, ServiceFixture.id)
            XCTAssertNotNil(store.values[origin])
            attempts += 1
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(account.accountID)
        XCTAssertNil(store.values[ServiceFixture.origin])
        XCTAssertEqual(account.state, .signedOut)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
}

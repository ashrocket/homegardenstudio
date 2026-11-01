import Foundation
import Security

@MainActor protocol AccountCredentialStore {
    func load(origin: String) throws -> StoredAccount?
    func save(_ account: StoredAccount, origin: String) throws
    func delete(origin: String) throws
    func delete(origin: String, accountID: UUID) throws
    func recoverableAccounts(origin: String) throws -> [RecoverableAccount]
    func selectAccount(origin: String, accountID: UUID) throws -> StoredAccount
}

extension AccountCredentialStore {
    // Compatibility for injected stores. Production Keychain implements the guarded overload below.
    func delete(origin: String, accountID: UUID) throws { try delete(origin: origin) }
    func recoverableAccounts(origin: String) throws -> [RecoverableAccount] {
        try load(origin: origin).map { [RecoverableAccount(id: $0.accountID)] } ?? []
    }
    func selectAccount(origin: String, accountID: UUID) throws -> StoredAccount {
        guard let account = try load(origin: origin), account.accountID == accountID else { throw GatewayError.accountRequired }
        return account
    }
}

nonisolated struct RecoverableAccount: Identifiable, Equatable, Sendable { let id: UUID }

@MainActor protocol KeychainSecurityClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor struct SystemKeychainSecurityClient: KeychainSecurityClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

@MainActor final class KeychainAccountStore: AccountCredentialStore {
    private let accessGroup: String
    private let security: any KeychainSecurityClient
    static let maximumRecoveryAccounts = 32

    init(accessGroup: String, security: any KeychainSecurityClient = SystemKeychainSecurityClient()) throws {
        guard !accessGroup.isEmpty, !accessGroup.contains("$("), accessGroup.utf8.count < 256 else {
            throw GatewayError.invalidConfiguration
        }
        self.accessGroup = accessGroup
        self.security = security
    }

    private func query(origin: String, recovery: Bool = false, accountID: UUID? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: recovery ? "com.ashleyraiteri.homegardenstudio.account.recovery.v1." + origin : "com.ashleyraiteri.homegardenstudio.account.v1",
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
         kSecUseDataProtectionKeychain as String: true]
        if !recovery { result[kSecAttrAccount as String] = origin }
        else if let accountID { result[kSecAttrAccount as String] = accountID.uuidString.lowercased() }
        return result
    }

    func load(origin: String) throws -> StoredAccount? {
        try read(query(origin: origin))
    }

    private func read(_ query: [String: Any]) throws -> StoredAccount? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = security.copyMatching(q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GatewayError.credentialsUnavailable }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data, data.count <= 4096,
              let account = try? JSONDecoder().decode(StoredAccount.self, from: data) else {
            throw GatewayError.corruptCredentials
        }
        try account.validate()
        // An unmarked legacy item is preserved, never silently claimed by a writer.
        guard item[kSecAttrGeneric as String] as? Data == identity(account.accountID) else {
            throw GatewayError.credentialConflict
        }
        return account
    }

    func save(_ account: StoredAccount, origin: String) throws {
        try account.validate()
        // Persist each identity under a distinct primary key before touching the active origin.
        // iCloud may resolve concurrent active-item writes, but cannot collapse different UUID keys.
        try preserve(account, origin: origin)
        let data = try JSONEncoder().encode(account)
        guard data.count <= 4096 else { throw GatewayError.corruptCredentials }
        var q = query(origin: origin)
        q[kSecAttrGeneric as String] = identity(account.accountID)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        // kSecAttrGeneric is a searchable generic-password attribute. Keep it immutable:
        // the UUID predicate and update are one Security operation, not a load/check/write race.
        let status = security.update(q, attributes: attributes)
        if status == errSecItemNotFound {
            var addition = q
            attributes.forEach { addition[$0.key] = $0.value }
            let inserted = security.add(addition)
            if inserted == errSecDuplicateItem {
                // Another device/process won the unique origin item. A bounded retry may update
                // that same UUID only; a different UUID remains untouched.
                let retried = security.update(q, attributes: attributes)
                if retried == errSecItemNotFound { throw GatewayError.credentialConflict }
                guard retried == errSecSuccess else { throw GatewayError.credentialsUnavailable }
            } else if inserted != errSecSuccess {
                throw GatewayError.credentialsUnavailable
            }
        } else if status != errSecSuccess { throw GatewayError.credentialsUnavailable }
    }

    func delete(origin: String) throws {
        // Callers must supply the remotely deleted identity; never delete by origin alone.
        throw GatewayError.credentialConflict
    }

    func delete(origin: String, accountID: UUID) throws {
        var q = query(origin: origin)
        q[kSecAttrGeneric as String] = identity(accountID)
        let status = security.delete(q)
        if status == errSecItemNotFound {
            // A different active identity belongs to another account and must remain intact.
            _ = try load(origin: origin)
        } else if status != errSecSuccess {
            throw GatewayError.credentialsUnavailable
        }
        var recovery = query(origin: origin, recovery: true, accountID: accountID)
        recovery[kSecAttrGeneric as String] = identity(accountID)
        let removed = security.delete(recovery)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw GatewayError.credentialsUnavailable }
    }

    func recoverableAccounts(origin: String) throws -> [RecoverableAccount] {
        var q = query(origin: origin, recovery: true)
        q[kSecReturnAttributes as String] = true
        // SecItem.h permits a numeric maximum. Do not load secrets or an unbounded result set.
        q[kSecMatchLimit as String] = Self.maximumRecoveryAccounts + 1
        let (status, value) = security.copyMatching(q)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw GatewayError.credentialsUnavailable }
        guard let items = value as? [[String: Any]], items.count <= Self.maximumRecoveryAccounts else {
            throw GatewayError.credentialsUnavailable
        }
        return try items.map { item in
            guard let name = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: name),
                  item[kSecAttrGeneric as String] as? Data == identity(id) else { throw GatewayError.corruptCredentials }
            return RecoverableAccount(id: id)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func selectAccount(origin: String, accountID: UUID) throws -> StoredAccount {
        guard let selected = try read(query(origin: origin, recovery: true, accountID: accountID)),
              selected.accountID == accountID else { throw GatewayError.accountRequired }
        let current = try load(origin: origin)
        if let current {
            try preserve(current, origin: origin)
            if current.accountID == accountID { return current }
        }
        var active = query(origin: origin)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(selected),
            kSecAttrGeneric as String: identity(accountID),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status: OSStatus
        if let current {
            // Explicit selection may change the active pointer, only while the observed identity
            // still matches. Both immutable identities already exist before this compare-and-set.
            active[kSecAttrGeneric as String] = identity(current.accountID)
            status = security.update(active, attributes: attributes)
        } else {
            attributes.forEach { active[$0.key] = $0.value }
            status = security.add(active)
        }
        if status == errSecItemNotFound || status == errSecDuplicateItem { throw GatewayError.credentialConflict }
        guard status == errSecSuccess else { throw GatewayError.credentialsUnavailable }
        return selected
    }

    private func preserve(_ account: StoredAccount, origin: String) throws {
        let q = query(origin: origin, recovery: true, accountID: account.accountID)
        if let saved = try read(q) {
            guard saved.accountID == account.accountID, saved.bearer == account.bearer else { throw GatewayError.credentialConflict }
            return
        }
        guard try recoverableAccounts(origin: origin).count < Self.maximumRecoveryAccounts else {
            throw GatewayError.credentialsUnavailable
        }
        var attributes = q
        // Immutable recovery keeps identity only. Replaying an old entitlement cache after a
        // later revocation would be misleading; selecting an inactive account requires refresh.
        let recovery = StoredAccount(accountID: account.accountID, bearer: account.bearer)
        attributes[kSecValueData as String] = try JSONEncoder().encode(recovery)
        attributes[kSecAttrGeneric as String] = identity(account.accountID)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = security.add(attributes)
        if status == errSecDuplicateItem {
            guard let saved = try read(q), saved.accountID == account.accountID, saved.bearer == account.bearer else {
                throw GatewayError.credentialConflict
            }
        } else if status != errSecSuccess { throw GatewayError.credentialsUnavailable }
    }

    private func identity(_ accountID: UUID) -> Data { Data(accountID.uuidString.lowercased().utf8) }
}

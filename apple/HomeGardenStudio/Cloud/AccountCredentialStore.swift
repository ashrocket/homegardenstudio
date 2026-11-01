import Foundation
import Security

@MainActor protocol AccountCredentialStore {
    func load(origin: String) throws -> StoredAccount?
    func save(_ account: StoredAccount, origin: String) throws
    func delete(origin: String) throws
}

@MainActor final class KeychainAccountStore: AccountCredentialStore {
    private let accessGroup: String

    init(accessGroup: String) throws {
        guard !accessGroup.isEmpty, !accessGroup.contains("$("), accessGroup.utf8.count < 256 else {
            throw GatewayError.invalidConfiguration
        }
        self.accessGroup = accessGroup
    }

    private func query(origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.ashleyraiteri.homegardenstudio.account.v1",
         kSecAttrAccount as String: origin,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
         kSecUseDataProtectionKeychain as String: true]
    }

    func load(origin: String) throws -> StoredAccount? {
        var q = query(origin: origin)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GatewayError.credentialsUnavailable }
        guard let data = result as? Data, data.count <= 4096,
              let account = try? JSONDecoder().decode(StoredAccount.self, from: data) else {
            throw GatewayError.corruptCredentials
        }
        try account.validate()
        return account
    }

    func save(_ account: StoredAccount, origin: String) throws {
        try account.validate()
        let data = try JSONEncoder().encode(account)
        guard data.count <= 4096 else { throw GatewayError.corruptCredentials }
        let q = query(origin: origin)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = q
            attributes.forEach { addition[$0.key] = $0.value }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw GatewayError.credentialsUnavailable
            }
        } else if status != errSecSuccess { throw GatewayError.credentialsUnavailable }
    }

    func delete(origin: String) throws {
        let status = SecItemDelete(query(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayError.credentialsUnavailable
        }
    }
}

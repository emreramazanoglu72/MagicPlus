//
//  KeychainStore.swift
//  MagicPlus
//

import Foundation
import Security

/// Generic passwords in the login keychain, for the secrets the app holds on someone's behalf.
///
/// API keys go here and nowhere else. `UserDefaults` is a plain plist any process can read and
/// every backup carries; a key stored there is a key published. The keychain is what macOS offers
/// for exactly this, and these four calls are the whole of what the app needs from it.
nonisolated enum KeychainStore {
    /// The service the agent's provider keys are filed under, one account per provider.
    static let agentService = "com.tabmenu.agent"

    /// - Returns: Whether the keychain took it. A caller that cannot tell is a settings pane that
    ///   says "saved in your keychain" over a key that was never written.
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update in place when it exists; add when it does not. Delete-then-add would work too,
        // but it drops the item's creation date and any access-control the user has set on it.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }

        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

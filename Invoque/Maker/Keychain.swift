import Foundation
import Security

/// Minimal generic-password Keychain wrapper — the only place secrets may
/// live (AGENTS.md: never UserDefaults, never the commands dir, never logs).
///
/// Used for the Maker's LLM API key. `service` namespaces the items so tests
/// can use a throwaway service without touching the real one.
struct Keychain {

    let service: String

    init(service: String = "com.invoque.Invoque") {
        self.service = service
    }

    // MARK: Read

    /// The stored password for `account`, or nil when absent. Unexpected
    /// errors also read as nil — a Keychain failure must not crash the
    /// settings UI; the result is simply "no key".
    func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                NSLog("Invoque: Keychain read failed (\(status)) for account \(account)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Write

    /// Stores `value` for `account`, overwriting any existing item. A nil or
    /// empty value deletes instead — an empty key is never a valid secret.
    func set(_ value: String?, account: String) {
        guard let value, !value.isEmpty else {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update-first so an existing item is replaced in place; on a
        // miss, add the fresh item.
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // Readable once the device has been unlocked; the key must not
            // silently migrate to other devices via backups.
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("Invoque: Keychain add failed (\(addStatus)) for account \(account)")
            }
        } else if status != errSecSuccess {
            NSLog("Invoque: Keychain update failed (\(status)) for account \(account)")
        }
    }

    // MARK: Delete

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

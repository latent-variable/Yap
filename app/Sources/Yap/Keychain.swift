import Foundation
import Security

/// Tiny generic-password Keychain wrapper. Used for the user's Hugging Face token
/// (a real account credential that unlocks Pocket voice cloning) — kept out of
/// UserDefaults / any plaintext file. Stored under this app's service id; the
/// value never leaves the machine except as the HF_TOKEN env handed to the local
/// backend when it loads the gated cloning model.
enum Keychain {
    private static let service = "dev.latentvariable.yap"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add keeps it idempotent and avoids SecItemUpdate edge cases.
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // empty = just clear it
        var add = base
        add[kSecValueData as String] = trimmed.data(using: .utf8)!
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

/// Account key + helpers for the Hugging Face token specifically.
enum HFToken {
    private static let account = "huggingface-token"
    static var value: String? { Keychain.get(account) }
    static var isSet: Bool { value != nil }
    static func set(_ v: String) { Keychain.set(v, account: account) }
    static func clear() { Keychain.delete(account) }
}

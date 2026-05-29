import Foundation
import Security
import OSLog

/// Keychain wrapper for the Claude API key. Mirrors the same service used by
/// CryptoVault but uses a different account so they don't collide.
public final class APIKeyVault: @unchecked Sendable {
    public static let shared = APIKeyVault()

    private static let service = "com.arushsharma.trackerbud"
    private static let account = "claudeAPIKey.v1"

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "APIKeyVault")
    public init() {}

    public func hasKey() -> Bool {
        get() != nil
    }

    public func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    public func set(key: String) throws {
        try clear()
        let data = Data(key.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "APIKeyVault", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain write failed (\(status))"
            ])
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "APIKeyVault", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain delete failed (\(status))"
            ])
        }
    }
}

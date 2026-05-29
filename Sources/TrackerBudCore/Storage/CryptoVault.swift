import Foundation
import CryptoKit
import Security
import OSLog

/// Per-field encryption for sensitive content.
///
/// We don't use SQLCipher because its SPM integration requires vendoring the
/// SQLCipher C source and configuring GRDBCustomSQLite — too much yak-shaving
/// for a personal-use build. Instead we AES-GCM encrypt the sensitive columns
/// (window titles, clipboard, URLs, file paths, OCR text) with a key stored in
/// the macOS Keychain. Structural columns (timestamps, source, type, token)
/// stay plaintext so pattern mining can query them efficiently.
///
/// Encoding: base64(nonce || ciphertext || tag), all combined as AES-GCM's
/// `combined` representation.
public final class CryptoVault: @unchecked Sendable {
    public static let shared = CryptoVault()

    private static let keychainService = "com.arushsharma.trackerbud"
    private static let keychainAccount = "fieldEncryptionKey.v1"
    private static let prefix = "v1:"

    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "CryptoVault")

    public init() {}

    /// Loads or generates the encryption key. Call once at startup.
    @discardableResult
    public func ensureKey() throws -> SymmetricKey {
        lock.lock()
        if let key = cachedKey { lock.unlock(); return key }
        lock.unlock()

        if let existing = try loadKeyFromKeychain() {
            lock.lock(); cachedKey = existing; lock.unlock()
            log.info("Loaded existing field-encryption key from Keychain")
            return existing
        }

        let new = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(new)
        lock.lock(); cachedKey = new; lock.unlock()
        log.info("Generated new field-encryption key and stored in Keychain")
        return new
    }

    public func encrypt(_ plaintext: String?) -> String? {
        guard let plaintext else { return nil }
        if plaintext.isEmpty { return "" }
        guard let key = try? ensureKey() else { return nil }
        guard let data = plaintext.data(using: .utf8) else { return nil }
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else { return nil }
            return Self.prefix + combined.base64EncodedString()
        } catch {
            log.error("Encryption failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func decrypt(_ encoded: String?) -> String? {
        guard let encoded else { return nil }
        if encoded.isEmpty { return "" }
        // Backward compatibility: anything without the prefix is plaintext.
        guard encoded.hasPrefix(Self.prefix) else { return encoded }
        let base64 = String(encoded.dropFirst(Self.prefix.count))
        guard let combined = Data(base64Encoded: base64) else { return nil }
        guard let key = try? ensureKey() else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            log.error("Decryption failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Keychain helpers

    private func loadKeyFromKeychain() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptoVaultError.keychainRead(status)
        }
        return SymmetricKey(data: data)
    }

    private func storeKeyInKeychain(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoVaultError.keychainWrite(status)
        }
    }

    /// Test/dev helper. Clears the cached key in memory AND deletes from Keychain.
    /// All previously encrypted data becomes unrecoverable.
    public func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CryptoVaultError.keychainDelete(status)
        }
        lock.lock(); cachedKey = nil; lock.unlock()
    }
}

public enum CryptoVaultError: Error, CustomStringConvertible {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)
    case keychainDelete(OSStatus)

    public var description: String {
        switch self {
        case .keychainRead(let s): return "Keychain read failed (\(s))"
        case .keychainWrite(let s): return "Keychain write failed (\(s))"
        case .keychainDelete(let s): return "Keychain delete failed (\(s))"
        }
    }
}

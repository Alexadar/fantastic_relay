import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    var description: String {
        if case .unexpectedStatus(let s) = self { return "keychain error \(s)" }
        return "keychain error"
    }
}

/// Minimal Keychain wrapper for small secrets (the signing key + password),
/// scoped to this app's bundle id as generic passwords.
///
/// Deliberately the LEGACY (file-based) keychain — NOT
/// `kSecUseDataProtectionKeychain`, which requires a keychain-access-group that
/// an unsandboxed Developer-ID app does not have (it would return
/// errSecMissingEntitlement). The data-protection keychain is the right call for
/// a sandboxed/MAS app; this app is neither.
enum KeychainStore {
    private static let service =
        Bundle.main.bundleIdentifier ?? "oleksandr.aisixteen.fantastic.relay"

    static func set(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func get(account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return out as? Data
    }

    static func setString(_ s: String, account: String) throws {
        try set(Data(s.utf8), account: account)
    }

    static func getString(account: String) throws -> String? {
        try get(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
}

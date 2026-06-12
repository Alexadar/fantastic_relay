import Crypto
import Foundation

/// Owns the control-plane Ed25519 (Curve25519.Signing) signing key + the relay
/// password in the Keychain.
///
/// The signing key is the relay's ONLY trust anchor: every device verifies
/// against its public key, so a lost or rotated key invalidates every paired
/// device. Therefore a persist failure is FATAL (we `throw`) — we must NEVER
/// swallow it and silently regenerate, which would rotate the pubkey out from
/// under the fleet.
enum IssuerKeyStore {
    private static let keyAccount = "control-plane-signing-key"
    private static let pwAccount = "control-plane-password"

    /// Load the signing key, generating + persisting one on first run.
    static func loadOrCreateSigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try KeychainStore.get(account: keyAccount) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.set(key.rawRepresentation, account: keyAccount)  // fatal on failure
        return key
    }

    static func loadPassword() throws -> String? {
        try KeychainStore.getString(account: pwAccount)
    }

    static func savePassword(_ s: String) throws {
        try KeychainStore.setString(s, account: pwAccount)
    }
}

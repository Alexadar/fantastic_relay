import Foundation

/// base64url (no padding) decode — there is no stdlib helper. Transform to
/// standard base64 (`-_` → `+/`, re-pad to a multiple of 4) then decode.
enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b.count % 4
        if rem > 0 {
            b += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: b)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

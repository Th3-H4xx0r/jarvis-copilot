import CryptoKit
import Foundation

/// The wire format of a Mac password approval. The iPhone signs it and the Mac checks it; this
/// one file compiles into both (`mac_app/JarvisMac/project.yml`), so the two can't disagree.
enum MacPasswordWire {
    /// What his iPhone signs: the kind, the request's nonce and time, and a hash of the exact
    /// text he was shown (so a server can't show one thing and get another).
    static func message(kind: String, nonce: String, ts: Int, context: String) -> Data {
        let digest = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data("jarvis-mac-password|\(kind)|\(nonce)|\(ts)|\(digest)".utf8)
    }

    /// The pairing code both show: the first 8 hex of SHA-256 of the iPhone's approval key.
    static func fingerprint(_ publicKeyB64: String) -> String? {
        guard let data = Data(base64Encoded: publicKeyB64) else { return nil }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation

/// The phone → computer hand-off of the QR pairing contract
/// (docs/superpowers/plans/2026-11-23-qr-pairing.md): the pairing code, the server and its
/// Cloudflare token, AES-256-GCM-sealed with the key from the computer's QR so nothing readable
/// crosses the home network. jc-client opens it with Python's `cryptography` AESGCM, whose
/// ciphertext is `ciphertext ‖ 16-byte tag` — the same bytes as below.
enum ComputerPairSeal {
    /// Additional authenticated data: binds the box to this protocol and version.
    static let aad = Data("jarvis-pair-computer-v1".utf8)

    /// `{"server","code","cf_id","cf_secret","ts"}` — `ts` in whole unix seconds; jc-client
    /// refuses one older than 120 s.
    static func plaintext(server: String, code: String, cfID: String, cfSecret: String, ts: Int) -> Data {
        let object: [String: Any] = ["server": server, "code": code, "cf_id": cfID,
                                     "cf_secret": cfSecret, "ts": ts]
        // Strings and an Int always serialise.
        return (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The POST body `{"v":1,"nonce":<base64 12 bytes>,"ct":<base64 ciphertext‖tag>}`. A fresh
    /// random nonce every call (jc-client refuses a reused one); `nonce` is only for the
    /// known-answer test.
    static func body(sealing plaintext: Data, key: Data, nonce: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw CryptoKitError.incorrectKeySize }
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce,
                                   authenticating: aad)
        let body: [String: Any] = [
            "v": 1,
            "nonce": gcmNonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            "ct": (box.ciphertext + box.tag).base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

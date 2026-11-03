import CryptoKit
import Foundation

/// A Mac password prompt answered from the phone. Allow is Face ID every time,
/// then a signature from the same Secure Enclave key the car uses
/// (`SecureEnclaveCarSigner`) over `jarvis-mac-password|<kind>|<nonce>|<ts>|<sha256(context)>`:
/// the hash ties his yes to the exact text he read, so a server can't swap it.
/// The server only relays it: the Mac checks the signature against the key it
/// paired with before it types anything, so the server can't say yes for him.
enum MacPasswordApproval {
    /// The push's `kind` and category (`mac_power.py` → `alert_phones`).
    static let pushKind = "mac_password"
    static let category = "MAC_PASSWORD"

    /// The exact bytes the Mac verifies (MacPassword.swift `ApprovalVerifier.message`).
    static func message(kind: String, nonce: String, ts: Int, context: String) -> Data {
        let digest = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data("jarvis-mac-password|\(kind)|\(nonce)|\(ts)|\(digest)".utf8)
    }

    /// The code the Mac shows when it pairs: first 8 hex of SHA-256 of this
    /// iPhone's own approval key, worked out here, never taken from the server.
    static func pairingCode(signer: any CarSigner = SecureEnclaveCarSigner.shared) -> String? {
        guard let key = try? signer.publicKey(), let data = Data(base64Encoded: key) else { return nil }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The card's title for what asked.
    static func title(kind: String) -> String {
        switch kind {
        case "sudo": return "sudo in Claude session"
        case "admin": return "Admin password"
        case "keychain": return "Keychain access"
        case "unlock": return "Unlock Mac"
        default: return "Mac password"
        }
    }

    /// "1:45 left" until the request lapses (as a Deny), "Expired" after.
    static func countdown(_ expires: Date, now: Date = Date()) -> String {
        let left = Int(expires.timeIntervalSince(now).rounded(.up))
        guard left > 0 else { return "Expired" }
        return String(format: "%d:%02d left", left / 60, left % 60)
    }

    /// Face ID, then the signed yes. The time is taken after Face ID so a slow
    /// prompt can't go stale on the Mac. Throws `CarSignError.cancelled` when he
    /// cancels Face ID — nothing is sent then.
    static func allow(_ request: MacPasswordRequest, api: AgentsAPI,
                      signer: any CarSigner = SecureEnclaveCarSigner.shared) async throws {
        let auth = try await signer.authenticate(reason: "Type your Mac password")
        let ts = Int(Date().timeIntervalSince1970)
        let signature = try await signer.sign(message(kind: request.kind, nonce: request.nonce, ts: ts,
                                                      context: request.context), auth: auth)
        try await api.macPasswordAnswer(id: request.id, decision: "allow", ts: ts,
                                        signature: signature.base64EncodedString())
    }

    /// No Face ID: saying no can't type anything.
    static func deny(_ request: MacPasswordRequest, api: AgentsAPI) async throws {
        try await api.macPasswordAnswer(id: request.id, decision: "deny")
    }
}

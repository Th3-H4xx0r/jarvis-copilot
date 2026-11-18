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
    /// Posted when a Mac password push arrives with the app open: the Agents tab
    /// reloads, so the card shows (or goes) even if the live link is down.
    static let changed = Notification.Name("jc.macPassword.changed")

    /// A Mac password request, or the "not filled" push after one.
    static func isMacPasswordPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let env = userInfo[NotificationAction.envelopeKey] as? [String: Any] ?? [:]
        let kind = env["kind"] as? String ?? userInfo["kind"] as? String
        return kind == pushKind || kind == "mac_password_failed"
    }

    /// The code the Mac shows when it pairs: first 8 hex of SHA-256 of this
    /// iPhone's own approval key, worked out here, never taken from the server.
    static func pairingCode(signer: any CarSigner = SecureEnclaveCarSigner.shared) -> String? {
        guard let key = try? signer.publicKey() else { return nil }
        return MacPasswordWire.fingerprint(key)
    }

    /// The card's title for what asked.
    static func title(kind: String) -> String {
        switch kind {
        case "sudo": return "sudo in Claude session"
        case "admin": return "Admin password"
        case "keychain": return "Keychain access"
        case "unlock": return "Unlock Mac"
        case "rdp": return "Remote Desktop"
        case "admin-run": return "Run as admin on your PC"
        case "pc-run": return "Approve a command on your PC"
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
        if let why = refusal(for: request) { throw Refused(errorDescription: why) }
        let auth = try await signer.authenticate(reason: MacPasswordSheetCopy.faceIDReason(for: request))
        let ts = Int(Date().timeIntervalSince1970)
        let signature = try await signer.sign(MacPasswordWire.message(kind: request.kind, nonce: request.nonce, ts: ts,
                                                      context: request.context), auth: auth)
        try await api.macPasswordAnswer(id: request.id, decision: "allow", ts: ts,
                                        signature: signature.base64EncodedString())
    }

    /// What this iPhone signs for: a server can't invent a kind (a "|" in it would shift the signed fields
    /// and pass one approval off as another), only the broker's nonce shape, and never an IT command with
    /// characters that make it read differently from what runs.
    static let signedKinds: Set<String> = ["sudo", "admin", "keychain", "unlock", "rdp", "admin-run", "pc-run"]

    struct Refused: LocalizedError { let errorDescription: String? }

    /// Why this request can't be approved here; nil when it can.
    static func refusal(for request: MacPasswordRequest) -> String? {
        guard signedKinds.contains(request.kind),
              request.nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            return "This request doesn't look right, so it wasn't approved."
        }
        if MacPasswordSheetCopy.itKinds.contains(request.kind),
           request.context.unicodeScalars.contains(where: { ($0.properties.generalCategory == .format
               || $0.properties.generalCategory == .control) && !"\n\t\r".unicodeScalars.contains($0) }) {
            return "This command has hidden characters, so it wasn't approved."
        }
        return nil
    }

    /// No Face ID: saying no can't type anything.
    static func deny(_ request: MacPasswordRequest, api: AgentsAPI) async throws {
        try await api.macPasswordAnswer(id: request.id, decision: "deny")
    }
}

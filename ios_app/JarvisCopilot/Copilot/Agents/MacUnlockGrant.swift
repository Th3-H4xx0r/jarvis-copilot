import CryptoKit
import Foundation
import Security

/// His unlock permission (2026-11-20): one Face ID lets Jarvis unlock the PC or Mac without asking each time, until
/// it ends (30 days at most, his pick). Signed with the same Secure Enclave key as every approval, over
/// `jarvis-mac-password|unlock-grant|<id>|<ts>|sha256("unlock-grant device=<id> until=<t>")`: the computer checks it
/// against the key it pins before typing anything, so the server can't make, stretch or move one.
enum MacUnlockGrant {
    struct Duration: Identifiable, Equatable {
        let label: String
        let seconds: Int
        var id: Int { seconds }
    }

    static let durations: [Duration] = [
        Duration(label: "1 hour", seconds: 3600), Duration(label: "8 hours", seconds: 8 * 3600),
        Duration(label: "1 day", seconds: 86400), Duration(label: "7 days", seconds: 7 * 86400),
        Duration(label: "30 days", seconds: MacPasswordWire.grantMaxSeconds),
    ]

    struct Draft {
        let id: String
        let ts: Int
        let until: Int
        let message: Data
    }

    static func make(device: String, seconds: Int, now: Date, id: String) -> Draft {
        let ts = Int(now.timeIntervalSince1970)
        let until = ts + min(max(seconds, 60), MacPasswordWire.grantMaxSeconds)
        return Draft(id: id, ts: ts, until: until,
                     message: MacPasswordWire.message(kind: MacPasswordWire.grantKind, nonce: id, ts: ts,
                                                      context: MacPasswordWire.grantContext(device: device, until: until)))
    }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Face ID, then the signed permission, sent to the server (which hands it to the computer).
    static func give(deviceId: String, name: String, seconds: Int, api: AgentsAPI,
                     signer: any CarSigner = SecureEnclaveCarSigner.shared) async throws {
        let label = durations.first { $0.seconds == seconds }?.label ?? "a while"
        let auth = try await signer.authenticate(reason: "Let Jarvis unlock \(name) without Face ID for \(label)")
        let draft = make(device: deviceId, seconds: seconds, now: Date(), id: newID())   // the time after Face ID
        let signature = try await signer.sign(draft.message, auth: auth)
        try await api.macUnlockGrant(deviceId: deviceId, grant: [
            "id": draft.id, "ts": draft.ts, "until": draft.until, "device": deviceId,
            "signature": signature.base64EncodedString(),
        ])
    }
}

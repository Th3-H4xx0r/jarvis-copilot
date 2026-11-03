import AppKit
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import LocalAuthentication
import OpenDirectory
import Security

/// Mac password autofill (spec 2026-11-02). The password lives only in this app's
/// Keychain item. jc-client asks (`password_fill`) after Pranav said yes; the app
/// checks that yes itself (his iPhone's Face ID signature against the key pinned
/// here, or a Touch ID it just ran) and only then types the password (admin,
/// Keychain, lock screen) or hands it back for sudo's askpass.
enum MacKeychain {
    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: NSUserName()]
    }

    static func read(_ service: String) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ service: String, _ value: String) throws {
        SecItemDelete(query(service) as CFDictionary)
        var q = query(service)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain refused it (\(status))."])
        }
    }

    static func delete(_ service: String) { SecItemDelete(query(service) as CFDictionary) }
}

enum MacPassword {
    static let service = "com.jarviscopilot.mac.password"

    static var isSet: Bool { read() != nil }
    static func read() -> String? { MacKeychain.read(service) }
    static func remove() { MacKeychain.delete(service) }

    /// Checks it against this Mac's own account before saving: a typo would only
    /// show up later, as a failed fill.
    static func store(_ password: String) throws {
        guard verify(password) else {
            throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "That isn't this Mac's password."])
        }
        try MacKeychain.write(service, password)
    }

    static func verify(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}

/// The iPhone's Face ID approval key, pinned on this Mac at pairing (in the
/// Keychain, so nothing else running as the user can swap it).
enum ApprovalKey {
    static let service = "com.jarviscopilot.mac.approval-key"
    static var pinned: String? { MacKeychain.read(service) }
    static func pin(_ publicKeyB64: String) throws { try MacKeychain.write(service, publicKeyB64) }
    static func unpin() { MacKeychain.delete(service) }

    /// First 8 hex of SHA-256 of the key: what the Mac and iPhone both show.
    static func fingerprint(_ publicKeyB64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyB64) else { return "?" }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Checks a signed iPhone yes: right key, fresh (≤ 300 s), and each nonce once.
final class ApprovalVerifier: @unchecked Sendable {
    static let freshness: TimeInterval = 300
    private var used: [String: Date] = [:]
    private let lock = NSLock()

    static func message(kind: String, nonce: String, ts: Int) -> Data {
        Data("jarvis-mac-password|\(kind)|\(nonce)|\(ts)".utf8)
    }

    func verify(kind: String, nonce: String, ts: Int, signatureB64: String, publicKeyB64: String,
                now: Date = Date()) -> Bool {
        guard !nonce.isEmpty, abs(now.timeIntervalSince1970 - Double(ts)) <= Self.freshness,
              let keyData = Data(base64Encoded: publicKeyB64),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sigData = Data(base64Encoded: signatureB64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              key.isValidSignature(signature, for: Self.message(kind: kind, nonce: nonce, ts: ts))
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        used = used.filter { now.timeIntervalSince($0.value) < Self.freshness * 2 }
        guard used[nonce] == nil else { return false }
        used[nonce] = now
        return true
    }
}

/// Types into whatever has the keyboard focus: the admin / Keychain dialog, or the
/// lock screen's password field. HID-level key events when the app has
/// Accessibility; System Events otherwise (the script arrives on stdin, so the
/// password never shows in a process list).
enum PasswordTyper {
    static func type(_ text: String) -> Bool {
        var id: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Jarvis: type the Mac password" as CFString, kIOPMUserActiveLocal, &id)
        usleep(400_000)   // a dark screen takes a moment to come up
        if AXIsProcessTrusted() {
            let source = CGEventSource(stateID: .hidSystemState)
            for unit in text.utf16 {
                var u = unit
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(8_000)
            }
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
            }
            return true
        }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to keystroke \"\(escaped)\" & return\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        pipe.fileHandleForWriting.write(Data(script.utf8))
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

@MainActor
final class MacPasswordFiller {
    static let shared = MacPasswordFiller()
    let verifier = ApprovalVerifier()
    /// Requests he allowed with Touch ID in the menu bar, waiting for their fill.
    private var touchApproved: Set<String> = []

    /// Menu bar "Allow with Touch ID": the check happens here, in the app.
    func allowWithTouchID(id: String, context: String, link: JcLink = .shared) {
        let la = LAContext()
        la.localizedCancelTitle = "Cancel"
        la.evaluatePolicy(.deviceOwnerAuthentication,
                          localizedReason: "type your Mac password for: \(context)") { ok, _ in
            DispatchQueue.main.async {
                guard ok else { return }
                self.touchApproved.insert(id)
                link.request(["type": "password_local_answer", "id": id, "decision": "allow"])
            }
        }
    }

    func deny(id: String, link: JcLink = .shared) {
        link.request(["type": "password_local_answer", "id": id, "decision": "deny"])
    }

    /// `password_fill` from jc-client.
    func handle(_ msg: [String: Any], link: JcLink = .shared) {
        let id = J.s(msg["id"]), kind = J.s(msg["kind"]), nonce = J.s(msg["nonce"])
        let proof = J.obj(msg["proof"])
        func reply(_ ok: Bool, password: String? = nil, error: String? = nil) {
            var body: [String: Any] = ["type": "password_fill_result", "id": id, "ok": ok]
            if let password { body["password"] = password }
            if let error { body["error"] = error }
            link.request(body)
        }
        let approved: Bool
        if J.b(proof["local"]) {
            approved = touchApproved.remove(id) != nil
        } else if let key = ApprovalKey.pinned, let ts = (proof["ts"] as? NSNumber)?.intValue {
            approved = verifier.verify(kind: kind, nonce: nonce, ts: ts, signatureB64: J.s(proof["signature"]),
                                       publicKeyB64: key)
        } else {
            approved = false
        }
        guard approved else {
            return reply(false, error: ApprovalKey.pinned == nil
                         ? "Pair your iPhone in Jarvis → Settings → Mac power first"
                         : "The approval didn't check out on the Mac")
        }
        guard let password = MacPassword.read() else {
            return reply(false, error: "No Mac password saved in Jarvis → Settings → Mac power")
        }
        if kind == "sudo" { return reply(true, password: password) }
        DispatchQueue.global(qos: .userInitiated).async {
            let typed = PasswordTyper.type(password)
            var cleared = true
            if typed && kind != "unlock" {
                cleared = false
                for _ in 0..<15 {
                    usleep(200_000)
                    if !SecurityAgentWatch.isShowing() { cleared = true; break }
                }
            }
            DispatchQueue.main.async {
                if !typed { reply(false, error: "Couldn't type on the Mac (Accessibility for Jarvis?)") }
                else if !cleared { reply(false, error: "Password didn't work") }
                else { reply(true) }
            }
        }
    }
}

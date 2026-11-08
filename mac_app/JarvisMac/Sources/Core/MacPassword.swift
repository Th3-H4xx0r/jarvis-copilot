import AppKit
import Carbon.HIToolbox
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

    /// What the Mac and iPhone both show.
    static func fingerprint(_ publicKeyB64: String) -> String { MacPasswordWire.fingerprint(publicKeyB64) ?? "?" }
}

/// Checks a signed iPhone yes: right key, fresh (≤ 300 s), and each nonce once.
final class ApprovalVerifier: @unchecked Sendable {
    static let freshness: TimeInterval = 300
    private var used: [String: Date] = [:]
    private let lock = NSLock()

    func verify(context: String, kind: String, nonce: String, ts: Int, signatureB64: String,
                publicKeyB64: String, now: Date = Date()) -> Bool {
        guard !nonce.isEmpty, abs(now.timeIntervalSince1970 - Double(ts)) <= Self.freshness,
              let keyData = Data(base64Encoded: publicKeyB64),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sigData = Data(base64Encoded: signatureB64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              key.isValidSignature(signature, for: MacPasswordWire.message(kind: kind, nonce: nonce, ts: ts, context: context))
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        used = used.filter { now.timeIntervalSince($0.value) < Self.freshness * 2 }
        guard used[nonce] == nil else { return false }
        used[nonce] = now
        return true
    }
}

enum ScreenLock {
    static var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

/// One key press: the key on his layout (with Shift / Option) and the character
/// itself, which goes on the event too so it reads right whatever the receiver uses.
struct KeyStroke: Equatable {
    var code: CGKeyCode
    var shift = false
    var option = false
    var unicode: [UInt16] = []
}

enum TypingStep: Equatable {
    case key(KeyStroke)
    case pause(useconds_t)
    /// Wait for the display to be awake and the lock screen to finish rebuilding.
    case settle
}

/// Which key types which character on the current keyboard layout.
enum KeyLayout {
    /// Call on the main thread (the Text Input Sources API asserts it).
    static func current() -> [UInt16: KeyStroke] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let kbType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { bytes -> [UInt16: KeyStroke] in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var map: [UInt16: KeyStroke] = [:]
            for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                let mods = UInt32((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8 & 0xFF
                for code in 0..<128 {   // lower codes first: the main keys win over the keypad
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, kbType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                    guard status == noErr, length == 1, chars[0] >= 0x20, chars[0] != 0x7F,
                          map[chars[0]] == nil else { continue }
                    map[chars[0]] = KeyStroke(code: CGKeyCode(code), shift: shift, option: option, unicode: [chars[0]])
                }
            }
            return map
        }
    }
}

/// Types into whatever has the keyboard focus: the admin / Keychain dialog, or the
/// lock screen's password field. HID-level key events when the app has
/// Accessibility; System Events otherwise (the script arrives on stdin, so the
/// password never shows in a process list).
enum PasswordTyper {
    static let deleteKey: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36

    /// What gets pressed, in order. At the lock screen the first key a sleeping
    /// screen gets stops the screen saver, and loginwindow then hides the password
    /// field, EMPTIES it and shows it again (~150 ms in its log, 2026-11-03): keys
    /// typed meanwhile go missing, so the field got a different tail of the password
    /// each try and macOS refused it. So: a Delete wakes it (it can't add a
    /// character or submit), wait for it to settle, Delete whatever is in the field
    /// (a field shown again empties itself here, harmlessly), then type, then Return.
    static func plan(_ text: String, lockScreen: Bool, layout: [UInt16: KeyStroke]) -> [TypingStep] {
        let delete = KeyStroke(code: deleteKey)
        var steps: [TypingStep] = []
        if lockScreen {
            steps += [.key(delete), .settle]
            for _ in 0..<(max(text.count, 16) + 8) { steps += [.key(delete), .pause(12_000)] }
            steps.append(.pause(400_000))
        }
        for ch in text {
            let units = Array(String(ch).utf16)
            let stroke = units.count == 1 ? layout[units[0]] : nil
            steps += [.key(stroke ?? KeyStroke(code: 0, unicode: units)), .pause(30_000)]
        }
        steps += [.pause(150_000), .key(KeyStroke(code: returnKey))]
        return steps
    }

    static func type(_ text: String, lockScreen: Bool, layout: [UInt16: KeyStroke]) -> Bool {
        var id: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Jarvis: type the Mac password" as CFString, kIOPMUserActiveLocal, &id)
        usleep(400_000)   // a dark screen takes a moment to come up
        if AXIsProcessTrusted() {
            let source = CGEventSource(stateID: .hidSystemState)
            for step in plan(text, lockScreen: lockScreen, layout: layout) {
                switch step {
                case .pause(let us): usleep(us)
                case .settle: settle()
                case .key(let k): post(k, source)
                }
            }
            return true
        }
        return systemEvents(text, lockScreen: lockScreen, clear: max(text.count, 16) + 8)
    }

    private static func post(_ k: KeyStroke, _ source: CGEventSource?) {
        var flags: CGEventFlags = []
        if k.shift { flags.insert(.maskShift) }
        if k.option { flags.insert(.maskAlternate) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: down) else { continue }
            e.flags = flags
            if !k.unicode.isEmpty {
                var units = k.unicode
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            }
            e.post(tap: .cghidEventTap)
            if down { usleep(6_000) }
        }
    }

    /// Display awake (≤ 3 s; a shut lid stays asleep), then time for loginwindow
    /// to stop the saver and rebuild the lock screen.
    private static func settle() {
        for _ in 0..<30 where CGDisplayIsAsleep(CGMainDisplayID()) != 0 { usleep(100_000) }
        usleep(1_200_000)
    }

    private static func systemEvents(_ text: String, lockScreen: Bool, clear: Int) -> Bool {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var script = "tell application \"System Events\"\n"
        if lockScreen {
            script += "key code 51\ndelay 1.6\nrepeat \(clear) times\nkey code 51\nend repeat\ndelay 0.4\n"
        }
        script += "keystroke \"\(escaped)\"\ndelay 0.15\nkey code 36\nend tell\n"
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
    /// Requests he allowed with Touch ID in the menu bar (id → kind), waiting for their fill.
    private var touchApproved: [String: String] = [:]

    /// Menu bar "Allow with Touch ID": the check happens here, in the app.
    func allowWithTouchID(id: String, kind: String, context: String, link: JcLink = .shared) {
        let la = LAContext()
        la.localizedCancelTitle = "Cancel"
        la.evaluatePolicy(.deviceOwnerAuthentication,
                          localizedReason: "type your Mac password for: \(context)") { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ok else { return }
                    self.touchApproved[id] = kind
                    link.request(["type": "password_local_answer", "request_id": id, "decision": "allow"])
                }
            }
        }
    }

    func deny(id: String, link: JcLink = .shared) {
        link.request(["type": "password_local_answer", "request_id": id, "decision": "deny"])
    }

    /// The `password_fill_result` sent back. The request goes in `request_id`:
    /// JcLink.send writes its own number into "id" (ui.sock's reply id), so a
    /// result keyed by "id" never found its request and jc-client gave up
    /// ("The Jarvis Mac app didn't answer") on every fill, even ones that worked.
    nonisolated static func result(id: String, ok: Bool, password: String? = nil, error: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["type": "password_fill_result", "request_id": id, "ok": ok]
        if let password { body["password"] = password }
        if let error { body["error"] = error }
        return body
    }

    /// `password_fill` from jc-client.
    func handle(_ msg: [String: Any], link: JcLink = .shared) {
        let id = J.s(msg["id"]), kind = J.s(msg["kind"]), nonce = J.s(msg["nonce"])
        let context = J.s(msg["context"])
        let proof = J.obj(msg["proof"])
        func reply(_ ok: Bool, password: String? = nil, error: String? = nil) {
            link.request(Self.result(id: id, ok: ok, password: password, error: error))
        }
        let approved: Bool
        if J.b(proof["local"]) {
            approved = touchApproved.removeValue(forKey: id) == kind && !kind.isEmpty
        } else if let key = ApprovalKey.pinned, let ts = (proof["ts"] as? NSNumber)?.intValue {
            approved = verifier.verify(context: context, kind: kind, nonce: nonce, ts: ts,
                                       signatureB64: J.s(proof["signature"]), publicKeyB64: key)
        } else {
            approved = false
        }
        guard approved else {
            return reply(false, error: ApprovalKey.pinned == nil && !J.b(proof["local"])
                         ? "Pair your iPhone in Jarvis → Settings → Mac power first"
                         : "The approval didn't check out on the Mac")
        }
        guard let password = MacPassword.read() else {
            return reply(false, error: "No Mac password saved in Jarvis → Settings → Mac power")
        }
        if kind == "sudo" { return reply(true, password: password) }
        // Only ever into the right place: the lock screen, or the password dialog
        // brought to the front. Never whatever app happens to have the keyboard.
        let unlock = kind == "unlock"
        if unlock {
            guard ScreenLock.isLocked else { return reply(false, error: "The Mac isn't locked") }
        } else {
            guard SecurityAgentWatch.isShowing() else { return reply(false, error: "The password dialog is gone") }
            if SecurityAgentWatch.isAboutJarvis(SecurityAgentWatch.dialogText()) {
                return reply(false, error: "That dialog asks for Jarvis's own saved password: refused")
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: SecurityAgentWatch.bundleID)
                .first?.activate()
        }
        let layout = KeyLayout.current()   // here: the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            if !unlock {
                usleep(300_000)
                let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                guard front == SecurityAgentWatch.bundleID else {
                    return DispatchQueue.main.async {
                        MainActor.assumeIsolated { reply(false, error: "Couldn't bring the password dialog to the front") }
                    }
                }
            }
            let typed = PasswordTyper.type(password, lockScreen: unlock, layout: layout)
            var cleared = false
            // macOS takes ~2 s to refuse a wrong one and a while to unlock: watch 8 s.
            for _ in 0..<(unlock ? 40 : 15) where typed {
                usleep(200_000)
                if unlock ? !ScreenLock.isLocked : !SecurityAgentWatch.isShowing() { cleared = true; break }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !typed { reply(false, error: "Couldn't type on the Mac (Accessibility for Jarvis?)") }
                    else if !cleared { reply(false, error: "Password didn't work") }
                    else { reply(true) }
                }
            }
        }
    }
}

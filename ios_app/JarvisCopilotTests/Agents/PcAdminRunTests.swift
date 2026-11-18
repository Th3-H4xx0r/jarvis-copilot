import CryptoKit
import XCTest
@testable import JarvisCopilot

/// The IT agent's Face ID approvals (W3): the sheet shows the exact command and why, and his
/// signature covers exactly that command — admin-run runs it elevated, pc-run unelevated.
final class PcAdminRunTests: XCTestCase {
    private func request(kind: String = "admin-run", context: String = "wsl --install --no-distribution",
                         why: String = "Enable WSL2") -> MacPasswordRequest {
        MacPasswordRequest(json: ["id": "r1", "device_id": "pc", "kind": kind, "context": context, "why": why,
                                  "nonce": "n", "expires": 2_000_000_000])
    }

    func testAdminRunCopy() {
        let r = request()
        XCTAssertEqual(MacPasswordSheetCopy.title(for: r), "Run as admin on your PC")
        XCTAssertEqual(MacPasswordApproval.title(kind: "admin-run"), "Run as admin on your PC")
        XCTAssertTrue(MacPasswordSheetCopy.isPC(r))
        XCTAssertTrue(MacPasswordSheetCopy.showsRequest(kind: r.kind, context: r.context))
        XCTAssertTrue(MacPasswordSheetCopy.monospaced(kind: "admin-run"))
        XCTAssertTrue(MacPasswordSheetCopy.monospaced(kind: "sudo"))
        XCTAssertFalse(MacPasswordSheetCopy.monospaced(kind: "unlock"))
        XCTAssertEqual(MacPasswordSheetCopy.symbol(kind: "admin-run"), "apple.terminal.fill")
        XCTAssertEqual(MacPasswordSheetCopy.allowHint(for: r), "Confirms with Face ID, then your PC runs this command once as admin")
        XCTAssertEqual(MacPasswordSheetCopy.warning(kind: "admin-run"),
                       "Runs once as admin on your PC. Approve only if you asked for this.")
        XCTAssertNil(MacPasswordSheetCopy.warning(kind: "unlock"))
    }

    func testPcRunCopy() {
        let r = request(kind: "pc-run", context: "winget remove x", why: "Remove the old one (uninstalls software)")
        XCTAssertEqual(MacPasswordSheetCopy.title(for: r), "Approve a command on your PC")
        XCTAssertTrue(MacPasswordSheetCopy.isPC(r) && MacPasswordSheetCopy.monospaced(kind: "pc-run"))
        XCTAssertEqual(MacPasswordSheetCopy.faceIDReason(for: r), "Run this command on your PC")
        XCTAssertEqual(MacPasswordSheetCopy.allowHint(for: r), "Confirms with Face ID, then your PC runs this command once")
        XCTAssertEqual(MacPasswordSheetCopy.warning(kind: "pc-run"), "Runs once on your PC. Approve only if you asked for this.")
        XCTAssertEqual(MacPasswordSheetCopy.symbol(kind: "pc-run"), "apple.terminal.fill")
    }

    func testAdminRunWhyDecodedAndShown() {
        let r = request()
        XCTAssertEqual(r.why, "Enable WSL2")
        XCTAssertEqual(MacPasswordSheetCopy.subtitle(for: r), "by the IT agent: Enable WSL2")
        XCTAssertNil(MacPasswordSheetCopy.subtitle(for: request(why: "")))
        XCTAssertEqual(MacPasswordRequest(json: ["id": "r", "kind": "unlock"]).why, "")
    }

    func testAdminRunSignsTheExactCommand() {
        let cmd = "winget install -e --id Docker.DockerDesktop "   // trailing space is part of what's signed
        let digest = SHA256.hash(data: Data(cmd.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(String(decoding: MacPasswordWire.message(kind: "admin-run", nonce: "n", ts: 1, context: cmd), as: UTF8.self),
                       "jarvis-mac-password|admin-run|n|1|\(digest)")
    }

    func testFaceIDReasonByKind() {
        XCTAssertEqual(MacPasswordSheetCopy.faceIDReason(for: request()), "Run as admin on your PC")
        XCTAssertEqual(MacPasswordSheetCopy.faceIDReason(for: request(kind: "unlock", context: "Unlock PC", why: "")),
                       "Type your PC password")
        XCTAssertEqual(MacPasswordSheetCopy.faceIDReason(for: request(kind: "sudo", context: "sudo ls", why: "")),
                       "Type your Mac password")
        let rdp = request(kind: "rdp", context: "{\"device\":\"Pranav-Desktop\",\"client\":\"ios\"}", why: "")
        XCTAssertEqual(MacPasswordSheetCopy.faceIDReason(for: rdp), MacPasswordSheetCopy.title(for: rdp))
    }

    // Bug sweep 2026-11-18 (B2, B6, B1).
    private let hex = String(repeating: "a", count: 32)

    func testOnlyKnownKindsAndBrokerNoncesAreSigned() {
        func req(_ kind: String, _ nonce: String) -> MacPasswordRequest {
            MacPasswordRequest(json: ["id": "r", "kind": kind, "context": "dir", "nonce": nonce, "expires": 2_000_000_000])
        }
        XCTAssertNil(MacPasswordApproval.refusal(for: req("admin-run", hex)))
        XCTAssertNil(MacPasswordApproval.refusal(for: req("unlock", hex)))
        XCTAssertNotNil(MacPasswordApproval.refusal(for: req("admin-run|x", "y")))   // a disguised approval
        XCTAssertNotNil(MacPasswordApproval.refusal(for: req("unlock", "x|y")))
        XCTAssertNotNil(MacPasswordApproval.refusal(for: req("something-new", hex)))
    }

    func testHiddenCharactersInACommandAreNotSigned() {
        func req(_ context: String) -> MacPasswordRequest {
            MacPasswordRequest(json: ["id": "r", "kind": "admin-run", "context": context, "nonce": hex, "expires": 2_000_000_000])
        }
        XCTAssertNotNil(MacPasswordApproval.refusal(for: req("echo safe\u{202E};del C:\\x")))
        XCTAssertNotNil(MacPasswordApproval.refusal(for: req("dir\u{200B}")))
        XCTAssertNil(MacPasswordApproval.refusal(for: req("dir\nwhoami\t/groups")))
    }

    func testHelperInstallMustTrustThisIPhone() {
        let mine = Data([0x04] + [UInt8](repeating: 1, count: 64)).base64EncodedString()
        let other = Data([0x04] + [UInt8](repeating: 2, count: 64)).base64EncodedString()
        let exe = "\"C:\\Users\\krish\\AppData\\Local\\Programs\\Jarvis\\app\\JarvisUnlock.exe\" --install S-1-5-21-1-2-3-1001"
        XCTAssertTrue(PcAdminCopy.trustsAnotherKey("\(exe) \(other)", own: mine))
        XCTAssertFalse(PcAdminCopy.trustsAnotherKey("\(exe) \(mine)", own: mine))
        XCTAssertFalse(PcAdminCopy.trustsAnotherKey(exe, own: mine))   // no key: the helper keeps the one it has
        XCTAssertTrue(PcAdminCopy.trustsAnotherKey("\(exe) \(mine)", own: nil))
    }
}

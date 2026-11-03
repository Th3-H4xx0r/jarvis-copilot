import CryptoKit
import XCTest
@testable import Jarvis

/// The Mac checks his iPhone's Face ID yes itself before typing the password.
final class MacPasswordTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private var pub: String { key.publicKey.x963Representation.base64EncodedString() }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let ctx = "sudo brew install x (started by zsh)"

    private func sign(_ kind: String, _ nonce: String, _ ts: Int, with k: P256.Signing.PrivateKey? = nil,
                      context: String? = nil) -> String {
        let msg = ApprovalVerifier.message(kind: kind, nonce: nonce, ts: ts, context: context ?? ctx)
        return try! (k ?? key).signature(for: msg).derRepresentation.base64EncodedString()
    }

    func testMessageFormat() {
        // sha256("hi") = 8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4
        XCTAssertEqual(String(data: ApprovalVerifier.message(kind: "sudo", nonce: "abc123", ts: 1_700_000_000,
                                                             context: "hi"), encoding: .utf8),
                       "jarvis-mac-password|sudo|abc123|1700000000|8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
    }

    func testSignatureRoundTrip() {
        let v = ApprovalVerifier()
        XCTAssertTrue(v.verify(context: ctx, kind: "admin", nonce: "n1", ts: 1_700_000_000,
                               signatureB64: sign("admin", "n1", 1_700_000_000), publicKeyB64: pub, now: now))
    }

    func testReplayAndStaleRefused() {
        let v = ApprovalVerifier()
        let sig = sign("sudo", "n2", 1_700_000_000)
        XCTAssertTrue(v.verify(context: ctx, kind: "sudo", nonce: "n2", ts: 1_700_000_000, signatureB64: sig, publicKeyB64: pub, now: now))
        XCTAssertFalse(v.verify(context: ctx, kind: "sudo", nonce: "n2", ts: 1_700_000_000, signatureB64: sig, publicKeyB64: pub, now: now),
                       "a nonce works once")
        let old = 1_700_000_000 - 301
        XCTAssertFalse(v.verify(context: ctx, kind: "sudo", nonce: "n3", ts: old, signatureB64: sign("sudo", "n3", old),
                                publicKeyB64: pub, now: now), "older than 300 s")
    }

    func testWrongKeyOrKindRefused() {
        let v = ApprovalVerifier()
        let other = P256.Signing.PrivateKey()
        XCTAssertFalse(v.verify(context: ctx, kind: "sudo", nonce: "n4", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "n4", 1_700_000_000, with: other), publicKeyB64: pub, now: now))
        // a yes for sudo can't open the lock screen
        XCTAssertFalse(v.verify(context: ctx, kind: "unlock", nonce: "n5", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "n5", 1_700_000_000), publicKeyB64: pub, now: now))
        XCTAssertFalse(v.verify(context: ctx, kind: "sudo", nonce: "", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "", 1_700_000_000), publicKeyB64: pub, now: now))
    }

    func testAYesForDifferentTextIsRefused() {
        // the server showed him "sudo ls" but the Mac's own request is something else
        let v = ApprovalVerifier()
        XCTAssertFalse(v.verify(context: ctx, kind: "sudo", nonce: "n6", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "n6", 1_700_000_000, context: "sudo ls"),
                                publicKeyB64: pub, now: now))
    }

    func testFingerprintIsEightHex() {
        XCTAssertEqual(ApprovalKey.fingerprint(pub).count, 8)
    }

    func testPushTokenMessage() {
        let msg = MacPowerBridge.tokenMessage(Data([0xab, 0x01]))
        XCTAssertEqual(msg["token"] as? String, "ab01")
        XCTAssertEqual(msg["type"] as? String, "mac_power_token")
    }
}

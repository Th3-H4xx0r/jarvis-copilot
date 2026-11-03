import CryptoKit
import XCTest
@testable import Jarvis

/// The Mac checks his iPhone's Face ID yes itself before typing the password.
final class MacPasswordTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private var pub: String { key.publicKey.x963Representation.base64EncodedString() }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sign(_ kind: String, _ nonce: String, _ ts: Int, with k: P256.Signing.PrivateKey? = nil) -> String {
        let msg = ApprovalVerifier.message(kind: kind, nonce: nonce, ts: ts)
        return try! (k ?? key).signature(for: msg).derRepresentation.base64EncodedString()
    }

    func testMessageFormat() {
        XCTAssertEqual(String(data: ApprovalVerifier.message(kind: "sudo", nonce: "abc123", ts: 1_700_000_000), encoding: .utf8),
                       "jarvis-mac-password|sudo|abc123|1700000000")
    }

    func testSignatureRoundTrip() {
        let v = ApprovalVerifier()
        XCTAssertTrue(v.verify(kind: "admin", nonce: "n1", ts: 1_700_000_000,
                               signatureB64: sign("admin", "n1", 1_700_000_000), publicKeyB64: pub, now: now))
    }

    func testReplayAndStaleRefused() {
        let v = ApprovalVerifier()
        let sig = sign("sudo", "n2", 1_700_000_000)
        XCTAssertTrue(v.verify(kind: "sudo", nonce: "n2", ts: 1_700_000_000, signatureB64: sig, publicKeyB64: pub, now: now))
        XCTAssertFalse(v.verify(kind: "sudo", nonce: "n2", ts: 1_700_000_000, signatureB64: sig, publicKeyB64: pub, now: now),
                       "a nonce works once")
        let old = 1_700_000_000 - 301
        XCTAssertFalse(v.verify(kind: "sudo", nonce: "n3", ts: old, signatureB64: sign("sudo", "n3", old),
                                publicKeyB64: pub, now: now), "older than 300 s")
    }

    func testWrongKeyOrKindRefused() {
        let v = ApprovalVerifier()
        let other = P256.Signing.PrivateKey()
        XCTAssertFalse(v.verify(kind: "sudo", nonce: "n4", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "n4", 1_700_000_000, with: other), publicKeyB64: pub, now: now))
        // a yes for sudo can't open the lock screen
        XCTAssertFalse(v.verify(kind: "unlock", nonce: "n5", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "n5", 1_700_000_000), publicKeyB64: pub, now: now))
        XCTAssertFalse(v.verify(kind: "sudo", nonce: "", ts: 1_700_000_000,
                                signatureB64: sign("sudo", "", 1_700_000_000), publicKeyB64: pub, now: now))
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

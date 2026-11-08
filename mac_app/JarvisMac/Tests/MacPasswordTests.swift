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
        let msg = MacPasswordWire.message(kind: kind, nonce: nonce, ts: ts, context: context ?? ctx)
        return try! (k ?? key).signature(for: msg).derRepresentation.base64EncodedString()
    }

    func testMessageFormat() {
        // sha256("hi") = 8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4
        XCTAssertEqual(String(data: MacPasswordWire.message(kind: "sudo", nonce: "abc123", ts: 1_700_000_000,
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

    // MARK: typing (the lock screen dropped the front of the password, 2026-11-03)

    private let fakeLayout: [UInt16: KeyStroke] = [
        UInt16(UInt8(ascii: "a")): KeyStroke(code: 0, unicode: [UInt16(UInt8(ascii: "a"))]),
        UInt16(UInt8(ascii: "A")): KeyStroke(code: 0, shift: true, unicode: [UInt16(UInt8(ascii: "A"))]),
        UInt16(UInt8(ascii: "1")): KeyStroke(code: 18, unicode: [UInt16(UInt8(ascii: "1"))]),
        UInt16(UInt8(ascii: "!")): KeyStroke(code: 18, shift: true, unicode: [UInt16(UInt8(ascii: "!"))]),
    ]

    private func keys(_ steps: [TypingStep]) -> [KeyStroke] {
        steps.compactMap { if case .key(let k) = $0 { return k } else { return nil } }
    }

    private func typed(_ strokes: [KeyStroke]) -> String {
        String(utf16CodeUnits: strokes.flatMap(\.unicode), count: strokes.flatMap(\.unicode).count)
    }

    func testLockScreenWakesWithDeleteSettlesAndClearsBeforeTyping() {
        let steps = PasswordTyper.plan("aA1!", lockScreen: true, layout: fakeLayout)
        guard let settle = steps.firstIndex(of: .settle) else { return XCTFail("no settle") }
        let before = keys(Array(steps[..<settle]))
        XCTAssertEqual(before, [KeyStroke(code: PasswordTyper.deleteKey)], "only a Delete before it settles")
        let after = keys(Array(steps[(settle + 1)...]))
        let firstChar = after.firstIndex { !$0.unicode.isEmpty }!
        XCTAssertTrue(after[..<firstChar].allSatisfy { $0.code == PasswordTyper.deleteKey }, "then only Deletes")
        XCTAssertGreaterThanOrEqual(firstChar, 16)
        XCTAssertEqual(after.last, KeyStroke(code: PasswordTyper.returnKey))
        XCTAssertEqual(after.filter { $0.code == PasswordTyper.returnKey }.count, 1, "one Return, at the end")
    }

    func testEveryCharacterOnceInOrderOnItsRealKey() {
        let strokes = keys(PasswordTyper.plan("aA1!é", lockScreen: false, layout: fakeLayout))
        XCTAssertFalse(strokes.contains { $0.code == PasswordTyper.deleteKey }, "a dialog isn't cleared")
        let chars = strokes.filter { !$0.unicode.isEmpty }
        XCTAssertEqual(typed(chars), "aA1!é")
        XCTAssertEqual(chars[1], KeyStroke(code: 0, shift: true, unicode: [UInt16(UInt8(ascii: "A"))]))
        XCTAssertEqual(chars[3].code, 18)
        XCTAssertTrue(chars[3].shift)
        XCTAssertEqual(chars[4], KeyStroke(code: 0, unicode: Array("é".utf16)), "not on the layout: the character alone")
        XCTAssertEqual(strokes.last?.code, PasswordTyper.returnKey)
    }

    func testCurrentLayoutTypesLowercaseLetters() {
        let layout = KeyLayout.current()
        let letters = "abcdefghijklmnopqrstuvwxyz".utf16
        XCTAssertGreaterThan(letters.filter { layout[$0] != nil }.count, 20)
    }

    func testFillResultNamesTheRequestOutsideTheLinkId() {
        let body = MacPasswordFiller.result(id: "abc", ok: false, error: "Password didn't work")
        XCTAssertEqual(body["request_id"] as? String, "abc")
        XCTAssertNil(body["id"], "JcLink.send overwrites \"id\" with its own number")
        XCTAssertEqual(body["type"] as? String, "password_fill_result")
    }

    func testPushTokenMessage() {
        let msg = MacPowerBridge.tokenMessage(Data([0xab, 0x01]))
        XCTAssertEqual(msg["token"] as? String, "ab01")
        XCTAssertEqual(msg["type"] as? String, "mac_power_token")
    }
}

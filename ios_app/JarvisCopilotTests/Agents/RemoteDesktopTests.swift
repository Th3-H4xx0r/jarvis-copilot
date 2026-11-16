import CryptoKit
import XCTest
@testable import JarvisCopilot
#if canImport(FreeRDP)
import FreeRDP
#endif

/// Remote Desktop on the iPhone (Task 8, docs/superpowers/plans/2026-11-15-remote-desktop.md).
@MainActor
final class RemoteDesktopTests: XCTestCase {

    // MARK: ECIES (the PC's credential frame)

    private func hex(_ s: String) -> Data {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    private func vector() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows_app/Jarvis.Tests/Crypto/ecies_vector.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        return obj.compactMapValues { $0 as? String }
    }

    func testEciesOpensVector() throws {
        let v = try vector()
        let recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(v["recipient_private_d"]!))
        XCTAssertEqual(recipient.publicKey.x963Representation, hex(v["recipient_public_x963"]!),
                       "the vector's key is the one the PC encrypted to")
        let text = try RdpEcies.open(ciphertextWithTag: hex(v["ciphertext_with_tag"]!),
                                     ephemeralPublicX963: hex(v["ephemeral_public_x963"]!),
                                     nonce: hex(v["nonce"]!)) { try recipient.sharedSecretFromKeyAgreement(with: $0) }
        XCTAssertEqual(text, v["plaintext_utf8"], "UTF-8 (the ✓) survives")

        // The frame as the server relays it: base64 parts.
        let frame: [String: Any] = ["ciphertext": hex(v["ciphertext_with_tag"]!).base64EncodedString(),
                                    "ephemeral_pub": hex(v["ephemeral_public_x963"]!).base64EncodedString(),
                                    "nonce": hex(v["nonce"]!).base64EncodedString()]
        let parts = try RdpEcies.parts(frame)
        XCTAssertEqual(parts.nonce, hex(v["nonce"]!))

        // A flipped byte fails (GCM), a wrong key fails: never garbage passwords.
        var tampered = hex(v["ciphertext_with_tag"]!)
        tampered[0] ^= 1
        XCTAssertThrowsError(try RdpEcies.open(ciphertextWithTag: tampered, ephemeralPublicX963: parts.ephemeral,
                                               nonce: parts.nonce) { try recipient.sharedSecretFromKeyAgreement(with: $0) })
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try RdpEcies.open(ciphertextWithTag: parts.ciphertext, ephemeralPublicX963: parts.ephemeral,
                                               nonce: parts.nonce) { try other.sharedSecretFromKeyAgreement(with: $0) })
        XCTAssertThrowsError(try RdpEcies.parts(["ciphertext": "!!"]))
    }

    func testDeviceKeyRoundTrip() throws {
        // The phone's own key (software in the simulator): encrypt like the PC, open like the phone.
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: RdpKey.shared.publicX963())
        XCTAssertEqual(pub.x963Representation.count, 65, "enc_pub is the 65-byte X9.63 point")
        let eph = P256.KeyAgreement.PrivateKey()
        let key = try eph.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: RdpEcies.info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data("hunter2 ✓".utf8), using: key)
        let text = try RdpCredentials.open(ciphertext: sealed.ciphertext + sealed.tag,
                                           ephemeralPub: eph.publicKey.x963Representation,
                                           nonce: Data(sealed.nonce))
        XCTAssertEqual(text, "hunter2 ✓")
    }

    func testSecretIsWiped() {
        let s = RdpSecret("pa55")
        XCTAssertEqual(s.withCString { String(cString: $0) }, "pa55")
        s.wipe()
        XCTAssertTrue(s.isWiped)
        XCTAssertEqual(s.withCString { String(cString: $0) }, "")
    }

    // MARK: reconnect, errors, states

    func testReconnectWindow() {
        let secret = RdpSecret("x")
        let dropped = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(RdpReconnect.canReuse(droppedAt: dropped, now: dropped.addingTimeInterval(59), secret: secret))
        XCTAssertTrue(RdpReconnect.canReuse(droppedAt: dropped, now: dropped.addingTimeInterval(60), secret: secret))
        XCTAssertFalse(RdpReconnect.canReuse(droppedAt: dropped, now: dropped.addingTimeInterval(61), secret: secret),
                       "after 60 s: a new session and Face ID")
        XCTAssertFalse(RdpReconnect.canReuse(droppedAt: nil, now: dropped, secret: secret))
        secret.wipe()
        XCTAssertFalse(RdpReconnect.canReuse(droppedAt: dropped, now: dropped, secret: secret), "nothing left to reuse")
    }

    func testNlaFailureMessage() {
        let msg = "Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)"
        for code in [RdpErrors.authenticationFailed, RdpErrors.logonFailure, RdpErrors.wrongPassword, RdpErrors.passwordExpired] {
            let f = RdpErrors.failure(code: code, message: "", wasConnected: false)
            XCTAssertEqual(f, .passwordRefused)
            XCTAssertEqual(RdpCopy.failure(f!, pc: "pranav-computer"), msg)
        }
        XCTAssertNil(RdpErrors.failure(code: 0, message: "", wasConnected: true), "a clean end")
        XCTAssertEqual(RdpErrors.failure(code: RdpErrors.connectFailed, message: "", wasConnected: true), .connectionLost)
        #if canImport(FreeRDP)
        // The mirrored constants are FreeRDP's own.
        XCTAssertEqual(RdpErrors.authenticationFailed, jrdp_error_auth_failed())
        XCTAssertEqual(RdpErrors.logonFailure, jrdp_error_logon_failure())
        XCTAssertEqual(RdpErrors.wrongPassword, jrdp_error_wrong_password())
        XCTAssertEqual(RdpErrors.passwordExpired, jrdp_error_password_expired())
        XCTAssertEqual(RdpErrors.accountDisabled, jrdp_error_account_disabled())
        XCTAssertEqual(RdpErrors.connectFailed, jrdp_error_connect_failed())
        #endif
    }

    func testStatesMatchWebFlow() {
        XCTAssertEqual(RdpState.names, ["idle", "checking", "warn", "approving", "connecting", "connected", "ended", "error"])
        let all: [RdpState] = [.idle, .checking, .warn(.inUse), .approving, .connecting, .connected, .ended(nil), .error(.asleep)]
        XCTAssertEqual(all.map(\.name), RdpState.names)
        XCTAssertTrue(RdpFailure.asleep.offersWake)
        XCTAssertEqual(RdpCopy.failure(.asleep, pc: "pranav-computer"), "pranav-computer is asleep")
        XCTAssertEqual(RdpCopy.failure(.noPassword, pc: "x"), "Save your Windows password in Jarvis on the PC first (Settings → PC power)")
    }

    func testCreateResponsesParse() {
        XCTAssertEqual(RdpCreateResult.parse(["warn": "game", "game_name": "Call of Duty"]), .warn(.game("Call of Duty")))
        XCTAssertEqual(RdpCreateResult.parse(["warn": "in_use"]), .warn(.inUse))
        XCTAssertEqual(RdpCreateResult.parse(["error": "asleep", "code": "asleep"]), .failure(.asleep))
        XCTAssertEqual(RdpCreateResult.parse(["error": "x", "code": "edition"]), .failure(.edition))
        if case .session(let s) = RdpCreateResult.parse(["session": ["id": "s1", "state": "approving", "expires_at": 100.0]]) {
            XCTAssertEqual(s.id, "s1"); XCTAssertEqual(s.state, "approving")
        } else { XCTFail() }
        let approved = RdpSessionInfo(json: ["session": ["id": "s1", "state": "approved", "username": "MicrosoftAccount\\a@b.com",
                                                         "credential": ["ciphertext": "AA==", "ephemeral_pub": "BB==", "nonce": "CC=="]]])
        XCTAssertEqual(approved?.credential?["nonce"], "CC==")
        XCTAssertNil(approved?.credential?["password"], "iOS never gets plaintext")
    }

    func testUsernameForms() {
        XCTAssertEqual(RdpClient.split("MicrosoftAccount\\krish@x.com").user, "MicrosoftAccount\\krish@x.com")
        XCTAssertEqual(RdpClient.split(".\\krish").user, "krish")
        XCTAssertEqual(RdpClient.split(".\\krish").domain, "")
        XCTAssertEqual(RdpClient.split("HOME\\krish").domain, "HOME")
        XCTAssertEqual(RdpClient.split("krish").user, "krish")
    }

    func testApprovalRequestMatchesThisSession() {
        let mine = MacPasswordRequest(json: ["id": "r1", "kind": "rdp", "nonce": "n",
                                             "context": #"{"client":"ios","device":"pc","enc_pub":"x","session":"s1"}"#])
        let other = MacPasswordRequest(json: ["id": "r2", "kind": "rdp", "nonce": "n", "context": #"{"session":"s2"}"#])
        let sudo = MacPasswordRequest(json: ["id": "r3", "kind": "sudo", "nonce": "n", "context": #"{"session":"s1"}"#])
        XCTAssertEqual(RdpApproval.request(for: "s1", in: [sudo, other, mine])?.id, "r1")
        XCTAssertNil(RdpApproval.request(for: "s9", in: [mine]))
    }

    func testModifiersLatchUntilNextKey() {
        var m = RdpModifiers()
        m.toggle(.ctrl)
        XCTAssertTrue(m.isOn(.ctrl))
        let events = m.events(for: .c)
        XCTAssertEqual(events.map(\.0), [.ctrl, .c, .c, .ctrl])
        XCTAssertEqual(events.map(\.1), [true, true, false, false])
        XCTAssertFalse(m.isOn(.ctrl), "used once, then released")
        XCTAssertEqual(RdpModifiers.chord([.ctrl, .alt, .delete]).map(\.1), [true, true, true, false, false, false])
        XCTAssertEqual(RdpTyping.scancode(for: "S"), RdpKeyCode(scancode: 0x1F))
    }

    // MARK: the flow against a fake server

    private final class FakeServer: RdpServer {
        var results: [RdpCreateResult] = []
        var creates: [Bool] = []
        var sessionState = "approving"
        var ended: [String] = []
        func create(deviceId: String, confirm: Bool, encPub: String) async throws -> RdpCreateResult {
            creates.append(confirm)
            return results.isEmpty ? .failure(.offline) : results.removeFirst()
        }
        func session(_ id: String) async throws -> RdpSessionInfo? {
            RdpSessionInfo(json: ["id": id, "state": sessionState])
        }
        func end(_ id: String) async { ended.append(id) }
        func relayURL(_ id: String) throws -> URLRequest { URLRequest(url: URL(string: "ws://127.0.0.1:1/x")!) }
    }

    private func model(_ server: FakeServer) -> RdpSessionModel {
        let m = RdpSessionModel(deviceId: "pc-1", pcName: "pranav-computer", server: server,
                                encPub: { Data(repeating: 4, count: 65) }, refreshRequests: { [] })
        m.pollInterval = 10_000_000
        return m
    }

    func testWarnThenConfirmGoesApproving() async {
        let server = FakeServer()
        server.results = [.warn(.game("Call of Duty")), .session(RdpSessionInfo(json: ["session": ["id": "s1", "state": "approving"]])!)]
        server.sessionState = "cancelled"
        let m = model(server)
        await m.run(confirm: false)
        XCTAssertEqual(m.state, .warn(.game("Call of Duty")))
        await m.run(confirm: true)
        XCTAssertEqual(server.creates, [false, true], "the second ask says confirm")
        XCTAssertEqual(m.state, .error(.notApproved), "denied on the PC side: nothing connects")
    }

    func testAsleepShowsWakeAndApprovalTimeoutEnds() async {
        let server = FakeServer()
        server.results = [.failure(.asleep)]
        let m = model(server)
        await m.run(confirm: false)
        XCTAssertEqual(m.state, .error(.asleep))

        let s2 = FakeServer()
        s2.results = [.session(RdpSessionInfo(json: ["session": ["id": "s2", "state": "approving"]])!)]
        let m2 = model(s2)
        m2.approvalTimeout = 0.1
        await m2.run(confirm: false)
        XCTAssertEqual(m2.state, .error(.notApproved))
        XCTAssertEqual(s2.ended, ["s2"], "an unanswered approval ends the session")
    }

    // MARK: where it shows

    func testRemoteDesktopActionInPicker() throws {
        let pc = ServerComputer(os: "windows", awake: true)
        let mac = ServerComputer(os: "macos", awake: true)
        XCTAssertTrue(ComputerPowerAction.actions(for: pc, remoteDesktopOn: true).contains(.remoteDesktop))
        XCTAssertFalse(ComputerPowerAction.actions(for: mac, remoteDesktopOn: true).contains(.remoteDesktop), "a Mac has none")
        XCTAssertFalse(ComputerPowerAction.actions(for: pc, remoteDesktopOn: false).contains(.remoteDesktop),
                       "hidden while the integration is off")
        XCTAssertEqual(ComputerPowerAction(skill: "computer_remote_desktop"), .remoteDesktop)
        XCTAssertNil(ComputerPowerAction.remoteDesktop.unavailable(ServerComputer(os: "windows", awake: false), name: "PC"),
                     "asleep: the session itself offers Wake")
        PowerState.shared.apply(list: [])          // everything on
        defer { PowerState.shared.apply(list: []) }
        let board = ServerDevice(id: "pc-1", name: "pranav-computer", online: true, capabilities: [], computer: pc)
        let section = ActionPickerIndex.computerSection(board, pc)
        XCTAssertTrue(section.rows.contains { $0.title == "Remote Desktop" })
        let macSection = ActionPickerIndex.computerSection(
            ServerDevice(id: "mac-1", name: "Mac", online: true, capabilities: [], computer: mac), mac)
        XCTAssertFalse(macSection.rows.contains { $0.title == "Remote Desktop" })
        XCTAssertTrue(ComputerToolsCopy.powerActions(pc, remoteDesktopOn: true).contains(.remoteDesktop))
    }

    func testTransferFolderNamesNeverOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try RdpTransfers.write(Data("1".utf8), name: "photo.jpg", to: dir)
        let b = try RdpTransfers.write(Data("2".utf8), name: "photo.jpg", to: dir)
        XCTAssertEqual(a.lastPathComponent, "photo.jpg")
        XCTAssertEqual(b.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(RdpTransfers.items(in: dir).count, 2)
    }
}

/// The PC's Face ID request for Remote Desktop, as the approval card shows it.
final class RdpApprovalCopyTests: XCTestCase {
    private func request(_ context: String) -> MacPasswordRequest {
        MacPasswordRequest(json: ["id": "r", "kind": "rdp", "nonce": "n", "context": context, "expires": 0])
    }

    func testRdpRequestTitleAndSubtitle() {
        let ios = request(#"{"client": "ios", "device": "pranav-computer", "enc_pub": "BB==", "session": "s1"}"#)
        XCTAssertEqual(MacPasswordSheetCopy.title(for: ios), "Remote Desktop to pranav-computer")
        XCTAssertEqual(MacPasswordSheetCopy.subtitle(for: ios), "from this iPhone")
        let web = request(#"{"client": "web", "device": "pranav-computer", "enc_pub": null, "session": "s2"}"#)
        XCTAssertEqual(MacPasswordSheetCopy.subtitle(for: web), "from the web")
        let bare = request(#"{"session": "s3"}"#)
        XCTAssertEqual(MacPasswordSheetCopy.title(for: bare), "Remote Desktop to your PC", "no device → your PC")
        XCTAssertNil(MacPasswordSheetCopy.subtitle(for: bare))
        XCTAssertEqual(MacPasswordSheetCopy.title(for: request("not json")), "Remote Desktop to your PC")
        XCTAssertFalse(MacPasswordSheetCopy.showsRequest(kind: "rdp", context: ios.context), "never the raw JSON")
        XCTAssertEqual(MacPasswordSheetCopy.symbol(kind: "rdp"), "display")
        XCTAssertEqual(MacPasswordApproval.title(kind: "rdp"), "Remote Desktop")
        let sudo = MacPasswordRequest(json: ["id": "r", "kind": "sudo", "nonce": "n", "context": "sudo ls"])
        XCTAssertNil(MacPasswordSheetCopy.subtitle(for: sudo))
    }
}


/// The bridge speaks the relay's rules (webui/api/rdp_relay.py): BINARY carries RDP, TEXT is a
/// keepalive both ends drop; the first bytes from FreeRDP go out at once and are pushed past the
/// proxy with a TEXT "k" (2026-11-16: the PC never saw the X.224 request without it).
final class RdpBridgeTests: XCTestCase {
    final class FakeLink: RdpWebSocketLink {
        private let lock = NSLock()
        private(set) var sent: [URLSessionWebSocketTask.Message] = []
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiting: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
        func resume() {}
        func cancel() {}
        func send(_ m: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
            lock.lock(); sent.append(m); lock.unlock()
            completion(nil)
        }
        func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            lock.lock()
            if !inbox.isEmpty {
                let m = inbox.removeFirst(); lock.unlock()
                DispatchQueue.global().async { completion(.success(m)) }
            } else { waiting = completion; lock.unlock() }
        }
        func push(_ m: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let w = waiting { waiting = nil; lock.unlock(); DispatchQueue.global().async { w(.success(m)) } }
            else { inbox.append(m); lock.unlock() }
        }
        var snapshot: [URLSessionWebSocketTask.Message] { lock.lock(); defer { lock.unlock() }; return sent }
    }

    private func describe(_ m: URLSessionWebSocketTask.Message) -> String {
        switch m {
        case .data(let d): return "data:" + d.map { String(format: "%02x", $0) }.joined()
        case .string(let s): return "text:" + s
        @unknown default: return "?"
        }
    }

    private func connect(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    private func wait(_ seconds: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { usleep(20_000) }
    }

    func testFirstBytesGoOutAsBinaryAtOnceThenAPush() async throws {
        let link = FakeLink()
        let bridge = RdpLoopbackBridge(request: URLRequest(url: URL(string: "wss://x/api/rdp/relay/s")!), makeLink: { _ in link })
        bridge.keepaliveEvery = 60
        let fd = connect(try await bridge.start())
        defer { close(fd); bridge.close() }
        let x224: [UInt8] = [0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0, 0, 0, 0, 0, 0x01, 0, 0x08, 0, 0x03, 0, 0, 0]
        _ = x224.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        wait(2) { link.snapshot.count >= 2 }
        let sent = link.snapshot.map(describe)
        XCTAssertEqual(sent.first, "data:" + x224.map { String(format: "%02x", $0) }.joined(),
                       "FreeRDP's connection request goes out at once, as BINARY")
        XCTAssertEqual(sent.dropFirst().first, "text:k", "then a TEXT push so the proxy doesn't hold it")
        XCTAssertEqual(bridge.bytesOut, x224.count)
    }

    func testTextFramesAreIgnoredBinaryReachesFreeRDP() async throws {
        let link = FakeLink()
        let bridge = RdpLoopbackBridge(request: URLRequest(url: URL(string: "wss://x/api/rdp/relay/s")!), makeLink: { _ in link })
        bridge.keepaliveEvery = 60
        let fd = connect(try await bridge.start())
        defer { close(fd); bridge.close() }
        wait(1) { bridge.closeReason == nil }
        usleep(200_000)
        link.push(.string("k"))
        link.push(.data(Data("hi".utf8)))
        link.push(.string("k"))
        link.push(.data(Data("!".utf8)))
        var got = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while got.count < 3 { let n = read(fd, &buf, buf.count); if n <= 0 { break }; got += buf[0..<n] }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "hi!", "only the BINARY bytes, never the relay's 'k'")
        wait(1) { bridge.textIgnored == 2 }
        XCTAssertEqual(bridge.textIgnored, 2)
        XCTAssertEqual(bridge.bytesIn, 3)
    }

    func testIdleBridgeSendsKeepalives() async throws {
        let link = FakeLink()
        let bridge = RdpLoopbackBridge(request: URLRequest(url: URL(string: "wss://x/api/rdp/relay/s")!), makeLink: { _ in link })
        bridge.keepaliveEvery = 0.2
        let fd = connect(try await bridge.start())
        defer { close(fd); bridge.close() }
        wait(2) { link.snapshot.count >= 2 }
        XCTAssertTrue(link.snapshot.count >= 2)
        XCTAssertTrue(link.snapshot.allSatisfy { if case .string("k") = $0 { return true }; return false },
                      "an idle bridge sends only TEXT keepalives")
    }
}

/// Exactly one Face ID: tapping Remote Desktop asks for none; Allow on the approval card asks once;
/// opening the password asks none (the key has no biometric of its own).
@MainActor
final class RdpOneFaceIDTests: XCTestCase {
    private final class Server: RdpServer {
        var credential: [String: Any]?
        func create(deviceId: String, confirm: Bool, encPub: String) async throws -> RdpCreateResult {
            .session(RdpSessionInfo(json: ["session": ["id": "sess0001", "state": "approving"]])!)
        }
        func session(_ id: String) async throws -> RdpSessionInfo? {
            if let credential { return RdpSessionInfo(json: ["id": id, "state": "approved", "username": ".\\u", "credential": credential]) }
            return RdpSessionInfo(json: ["id": id, "state": "approving"])
        }
        func end(_ id: String) async {}
        func relayURL(_ id: String) throws -> URLRequest { URLRequest(url: URL(string: "ws://127.0.0.1:1/x")!) }
    }

    func testTheFlowAsksFaceIDExactlyOnce() async throws {
        XCTAssertEqual(RdpKey.accessFlags, [.privateKeyUsage], "no biometry on the key: no second prompt at decrypt")
        let server = Server()
        var faceIDs = 0
        let request = MacPasswordRequest(json: ["id": "r1", "kind": "rdp", "nonce": "n", "expires": Date().timeIntervalSince1970 + 60,
                                                "context": #"{"client": "ios", "device": "pc", "enc_pub": "x", "session": "sess0001"}"#])
        let m = RdpSessionModel(deviceId: "pc-1", pcName: "pranav-computer", server: server,
                                refreshRequests: { [request] }, answer: { _, allow in if allow { faceIDs += 1 } })
        m.pollInterval = 20_000_000
        m.start()
        for _ in 0..<100 where m.approvalRequest == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(m.approvalRequest?.id, "r1", "the approval card shows on the Remote Desktop screen")
        XCTAssertEqual(faceIDs, 0, "tapping Remote Desktop asks no Face ID")
        XCTAssertTrue(RdpApproval.isInline(request), "the generic password sheet skips it: one card")
        XCTAssertNil(MacPasswordQueue.next([request], snoozed: []))

        // The PC encrypts the password to this phone's key once he allows.
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: RdpKey.shared.publicX963())
        let eph = P256.KeyAgreement.PrivateKey()
        let key = try eph.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: RdpEcies.info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data("pw".utf8), using: key)
        await m.allow()
        XCTAssertEqual(faceIDs, 1)
        server.credential = ["ciphertext": (sealed.ciphertext + sealed.tag).base64EncodedString(),
                             "ephemeral_pub": eph.publicKey.x963Representation.base64EncodedString(),
                             "nonce": Data(sealed.nonce).base64EncodedString()]
        for _ in 0..<150 where m.state == .approving { try await Task.sleep(nanoseconds: 20_000_000) }
        if case .error(.other(let why)) = m.state { XCTAssertFalse(why.contains("open the password"), why) }
        XCTAssertNotEqual(m.state, .approving, "the credential opened and it moved on to connecting")
        XCTAssertEqual(faceIDs, 1, "still exactly one Face ID")
        XCTAssertFalse(RdpApproval.isInline(request), "the inline claim ends with the approval")
        m.disconnect()
    }
}

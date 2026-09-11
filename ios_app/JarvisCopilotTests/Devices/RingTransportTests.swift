import XCTest
@testable import JarvisCopilot

/// A scripted ring: each write pops the next reply queued for its opcode and delivers it
/// back through the transport, like CoreBluetooth notifications would.
@MainActor
final class FakeRingLink: RingLink {
    var isLinkReady = true
    weak var transport: RingTransport?
    var replyDelay: TimeInterval = 0
    private(set) var sent: [(channel: RingChannel, bytes: [UInt8])] = []
    private var scripts: [String: [[Data]]] = [:]

    private func key(_ channel: RingChannel, _ cmd: UInt8) -> String { "\(channel.rawValue):\(cmd)" }

    /// Queues one reply — a list of notifications — for the next write of `cmd`.
    func script(_ cmd: UInt8, on channel: RingChannel = .command, _ notifications: [Data]) {
        scripts[key(channel, cmd), default: []].append(notifications)
    }

    /// Opcodes written, in order.
    var sentCommands: [UInt8] {
        sent.map { $0.channel == .command ? $0.bytes[0] : $0.bytes[1] }
    }

    /// Payloads written for `cmd` (command payloads are the 14 bytes after the opcode).
    func payloads(_ cmd: UInt8, on channel: RingChannel = .command) -> [[UInt8]] {
        sent.filter { $0.channel == channel && ($0.channel == .command ? $0.bytes[0] : $0.bytes[1]) == cmd }
            .map { $0.channel == .command ? Array($0.bytes[1..<15]) : Array($0.bytes.dropFirst(6)) }
    }

    func deliver(_ data: Data, on channel: RingChannel = .command) {
        transport?.receive(data, on: channel)
    }

    func send(_ data: Data, on channel: RingChannel) {
        let bytes = [UInt8](data)
        sent.append((channel, bytes))
        let cmd = channel == .command ? bytes[0] : bytes[1]
        guard var queued = scripts[key(channel, cmd)], !queued.isEmpty else { return }
        let reply = queued.removeFirst()
        scripts[key(channel, cmd)] = queued
        let delay = replyDelay
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            for notification in reply { self?.transport?.receive(notification, on: channel) }
        }
    }
}

@MainActor
func makeRingTransport(_ link: FakeRingLink) -> RingTransport {
    let transport = RingTransport(timing: .init(reply: 0.25, packetGap: 0.25, bigDataGap: 0.3, idle: 0.1))
    transport.link = link
    link.transport = transport
    return transport
}

@MainActor
final class RingTransportTests: XCTestCase {

    private var link: FakeRingLink!
    private var transport: RingTransport!

    override func setUp() async throws {
        link = FakeRingLink()
        transport = makeRingTransport(link)
    }

    func testASingleReplyCompletesTheTransaction() async throws {
        link.script(0x03, [RingProtocol.frame(0x03, [80, 0])])
        let reply = try await transport.perform(.battery, until: .single)
        XCTAssertEqual(reply.first?.payload.prefix(2), [80, 0])
    }

    func testAnErrorReplyThrowsRejected() async {
        link.script(0x16, [RingProtocol.frame(0x96, [1])])
        do {
            _ = try await transport.perform(.readHeartRateMonitor, until: .single)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? RingError, .rejected(0x16))
        }
    }

    func testATimeoutThrowsAndTheQueueMovesOn() async throws {
        link.script(0x3C, [RingProtocol.frame(0x3C, [0, 1])])
        do {
            _ = try await transport.perform(.battery, until: .single)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? RingError, .timeout(0x03))
        }
        let reply = try await transport.perform(.deviceSupport, until: .single)
        XCTAssertEqual(reply.count, 1)
    }

    func testPacketsCollectUntilTheLastOne() async throws {
        let header = RingProtocol.frame(0x43, [0xF0, 0, 1])
        let first = RingProtocol.frame(0x43, [0x26, 0x09, 0x11, 40, 0, 2, 1, 0, 2, 0, 3, 0])
        let last = RingProtocol.frame(0x43, [0x26, 0x09, 0x11, 41, 1, 2, 1, 0, 2, 0, 3, 0])
        link.script(0x43, [header, first, last])
        var isFirst = true
        let frames = try await transport.perform(.stepDetail(dayOffset: 0), until: .packets { inbound in
            defer { isFirst = false }
            return RingDecode.isSlotReplyLast(inbound.payload, first: isFirst)
        })
        XCTAssertEqual(frames.count, 3)
    }

    func testIdleCollectsUntilQuietAndReturnsEmptyWhenNothingComes() async throws {
        link.script(0x28, on: .bigData, [RingProtocol.bigDataFrame(0x28, [0, 1, 2, 3]),
                                          RingProtocol.bigDataFrame(0x28, [1, 4, 5, 6])])
        let frames = try await transport.perform(.bigManualHeartRate(all: true), until: .idle)
        XCTAssertEqual(frames.map(\.payload), [[0, 1, 2, 3], [1, 4, 5, 6]])

        let nothing = try await transport.perform(.bigManualSpO2(all: true), until: .idle)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testUnsolicitedFramesReachTheHandlerDuringATransaction() async throws {
        var unsolicited: [RingInbound] = []
        transport.onUnsolicited = { unsolicited.append($0) }
        link.script(0x03, [RingProtocol.frame(0x73, [12, 50, 0]), RingProtocol.frame(0x03, [50, 0])])
        let reply = try await transport.perform(.battery, until: .single)
        XCTAssertEqual(reply.first?.cmd, 0x03)
        XCTAssertEqual(unsolicited.map(\.cmd), [0x73])
    }

    func testBigDataRepliesAreReassembledFromChunks() async throws {
        let payload: [UInt8] = [0, 5, 1, 0] + [UInt8](repeating: 70, count: 40)
        link.script(0x75, on: .bigData, RingProtocol.chunks(RingProtocol.bigDataFrame(0x75, payload), size: 20))
        let reply = try await transport.perform(.bigIntervalHeartRate(dayOffset: 0, packet: 0), until: .single)
        XCTAssertEqual(reply.first?.payload, payload)
    }

    func testALinkDropFailsTheCurrentAndQueuedTransactions() async throws {
        let first = Task { try await self.transport.perform(.battery, until: .single) }
        let second = Task { try await self.transport.perform(.deviceSupport, until: .single) }
        try await Task.sleep(nanoseconds: 30_000_000)
        transport.linkDropped()
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected notConnected")
            } catch {
                XCTAssertEqual(error as? RingError, .notConnected)
            }
        }
    }

    func testRequestsAreSerialised() async throws {
        link.replyDelay = 0.05
        link.script(0x03, [RingProtocol.frame(0x03, [1, 0])])
        link.script(0x3C, [RingProtocol.frame(0x3C, [0])])
        let first = Task { try await self.transport.perform(.battery, until: .single) }
        let second = Task { try await self.transport.perform(.deviceSupport, until: .single) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(link.sentCommands, [0x03])
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(link.sentCommands, [0x03, 0x3C])
    }

    func testWriteOnlyRequestsCompleteImmediately() async throws {
        let reply = try await transport.perform(.findRing, until: .none)
        XCTAssertTrue(reply.isEmpty)
        XCTAssertEqual(link.payloads(0x50).first?.prefix(2), [0x55, 0xAA])
    }

    func testNothingIsSentWithoutALink() async {
        link.isLinkReady = false
        do {
            _ = try await transport.perform(.battery, until: .single)
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? RingError, .notConnected)
        }
        XCTAssertTrue(link.sent.isEmpty)
    }
}

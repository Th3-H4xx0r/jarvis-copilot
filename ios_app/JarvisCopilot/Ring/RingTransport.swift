import Foundation

/// The byte pipe a ring session talks through — CoreBluetooth in the app, a fake in tests.
@MainActor
protocol RingLink: AnyObject {
    var isLinkReady: Bool { get }
    /// Whether the ring exposes the large-data service.
    var hasBigDataChannel: Bool { get }
    func send(_ data: Data, on channel: RingChannel)
}

enum RingError: LocalizedError, Equatable {
    case notConnected
    case timeout(UInt8)
    case rejected(UInt8)
    case unsupported(String)
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "ring is not connected over Bluetooth"
        case .timeout(let cmd): return String(format: "ring did not answer command 0x%02X", cmd)
        case .rejected(let cmd): return String(format: "ring rejected command 0x%02X", cmd)
        case .unsupported(let what): return "this ring doesn't support \(what)"
        case .busy(let what): return "ring is busy: \(what)"
        }
    }
}

/// How a transaction knows it has its whole reply.
enum RingUntil {
    /// Write only; nothing to wait for.
    case none
    /// The first frame with a matching opcode.
    case single
    /// Every matching frame until the closure says that one was the last.
    case packets((RingInbound) -> Bool)
    /// Every matching frame until the ring goes quiet — for replies with no end marker.
    case idle
}


/// Serialises request/reply transactions over both ring channels.
///
/// The SDK runs one GATT operation at a time and matches replies by opcode, so this does the
/// same: one transaction in flight, replies matched on (channel, opcode), everything else
/// handed to `onUnsolicited`. The timeout restarts on every consumed frame so long
/// multi-packet replies aren't cut off.
@MainActor
final class RingTransport {
    struct Timing {
        var reply: TimeInterval = 2.5
        var packetGap: TimeInterval = 3
        var bigDataGap: TimeInterval = 6
        var idle: TimeInterval = 1.2
    }

    weak var link: RingLink?
    var timing: Timing
    var onUnsolicited: ((RingInbound) -> Void)?
    /// Every frame in either direction, decoded meaning left to `RingLog`.
    var onFrame: ((RingFrame) -> Void)?

    private final class Pending {
        let request: RingRequest
        let accepting: Set<UInt8>
        let until: RingUntil
        var collected: [RingInbound] = []
        let continuation: CheckedContinuation<[RingInbound], Error>

        init(request: RingRequest, accepting: Set<UInt8>, until: RingUntil,
             continuation: CheckedContinuation<[RingInbound], Error>) {
            self.request = request
            self.accepting = accepting
            self.until = until
            self.continuation = continuation
        }
    }

    private var queue: [Pending] = []
    private var current: Pending?
    private var timer: Task<Void, Never>?
    private var assembler = RingBigDataAssembler()

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    var isBusy: Bool { current != nil || !queue.isEmpty }

    /// Sends `request` and waits for its reply. `accepting` lists the opcodes that belong to
    /// this transaction (defaults to the request's own).
    func perform(_ request: RingRequest, accepting: Set<UInt8>? = nil, until: RingUntil) async throws -> [RingInbound] {
        guard let link, link.isLinkReady else { throw RingError.notConnected }
        // Without the service a large-data request would only sit out its timeout.
        if request.channel == .bigData, !link.hasBigDataChannel {
            throw RingError.unsupported("the large-data channel")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Pending(request: request, accepting: accepting ?? [request.cmd],
                                 until: until, continuation: continuation))
            pump()
        }
    }

    func receive(_ data: Data, on channel: RingChannel) {
        switch channel {
        case .command:
            guard let parsed = RingProtocol.parseCommand(data) else { return }
            onFrame?(RingFrame(outbound: false, channel: .command, cmd: parsed.inbound.cmd,
                               payload: parsed.inbound.payload, isError: parsed.inbound.isError,
                               note: parsed.checksumValid ? "" : "bad checksum, dropped"))
            // A corrupt settings reply would otherwise be written back by the next change.
            guard parsed.checksumValid else { return }
            route(parsed.inbound)
        case .bigData:
            for frame in assembler.append(data) {
                if !frame.crcValid {
                    JcLog.devices.notice("ring: large-data CRC mismatch on 0x\(String(format: "%02X", frame.inbound.cmd), privacy: .public)")
                }
                onFrame?(RingFrame(outbound: false, channel: .bigData, cmd: frame.inbound.cmd,
                                   payload: frame.inbound.payload, note: frame.crcValid ? "" : "CRC mismatch"))
                route(frame.inbound)
            }
        }
    }

    /// The link went away: nothing in flight or queued can complete.
    func linkDropped() {
        assembler.reset()
        failAll(RingError.notConnected)
    }

    // MARK: Queue

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        guard let link, link.isLinkReady else {
            failAll(RingError.notConnected)
            return
        }
        let next = queue.removeFirst()
        current = next
        onFrame?(RingFrame(outbound: true, channel: next.request.channel, cmd: next.request.cmd,
                           payload: next.request.payload))
        link.send(next.request.bytes, on: next.request.channel)
        if case .none = next.until {
            finish(.success([]))
        } else {
            armTimer()
        }
    }

    private func route(_ inbound: RingInbound) {
        guard let pending = current, pending.request.channel == inbound.channel,
              pending.accepting.contains(inbound.cmd) else {
            onUnsolicited?(inbound)
            return
        }
        if inbound.isError {
            finish(.failure(RingError.rejected(inbound.cmd)))
            return
        }
        pending.collected.append(inbound)
        switch pending.until {
        case .none:
            onUnsolicited?(inbound)
        case .single:
            finish(.success(pending.collected))
        case .packets(let isLast):
            if isLast(inbound) {
                finish(.success(pending.collected))
            } else {
                armTimer()
            }
        case .idle:
            armTimer()
        }
    }

    private func armTimer() {
        timer?.cancel()
        guard let pending = current else { return }
        let bigData = pending.request.channel == .bigData
        let firstWait = bigData ? timing.bigDataGap : timing.reply
        let seconds: TimeInterval
        switch pending.until {
        case .idle:
            seconds = pending.collected.isEmpty ? firstWait : timing.idle
        case .packets:
            seconds = pending.collected.isEmpty ? firstWait : (bigData ? timing.bigDataGap : timing.packetGap)
        case .none, .single:
            seconds = firstWait
        }
        timer = Task { [weak self, pending] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timedOut(pending)
        }
    }

    private func timedOut(_ pending: Pending) {
        guard current === pending else { return }
        switch pending.until {
        case .idle:
            finish(.success(pending.collected))
        case .packets where !pending.collected.isEmpty:
            // A reply that stopped short (e.g. today's future slots) is still worth keeping.
            finish(.success(pending.collected))
        default:
            finish(.failure(RingError.timeout(pending.request.cmd)))
        }
    }

    private func finish(_ result: Result<[RingInbound], Error>) {
        timer?.cancel()
        timer = nil
        guard let done = current else { return }
        current = nil
        done.continuation.resume(with: result)
        pump()
    }

    private func failAll(_ error: Error) {
        timer?.cancel()
        timer = nil
        let pending = (current.map { [$0] } ?? []) + queue
        current = nil
        queue.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

}

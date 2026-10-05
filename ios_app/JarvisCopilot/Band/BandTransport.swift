import CoreBluetooth
import Foundation

/// The band's Bluetooth side, as the transport needs it.
@MainActor
protocol BandLink: AnyObject {
    var isLinkReady: Bool { get }
    func send(_ frame: [UInt8])
}

enum BandError: LocalizedError, Equatable {
    case notConnected
    case timeout(UInt8)
    /// The band said no (busy, not worn, not supported…).
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The band isn't connected."
        case .timeout(let op): return String(format: "The band didn't answer (0x%02X).", op)
        case .refused(let why): return why
        }
    }
}

/// The Veepoo band's GATT: one service, a write characteristic and a notify one. On the E910
/// the roles are the reverse of the SDK's UUID order: write is `…0003`, notify `…0002`.
enum BandGATT {
    static let service = CBUUID(string: "F0080001-0451-4000-B000-000000000000")
    static let write = CBUUID(string: "F0080003-0451-4000-B000-000000000000")
    static let notify = CBUUID(string: "F0080002-0451-4000-B000-000000000000")
    /// What the band advertises (the Veepoo service only appears once connected).
    static let advertised = CBUUID(string: "FEE7")
    /// Veepoo's manufacturer id in the advertisement (its first 6 data bytes are the MAC).
    static let manufacturer: UInt16 = 0xF8F8
}

/// One request at a time: a 20-byte frame out, then reply frames collected until the request's
/// `until` says the reply is whole (or the time runs out). Frames nobody asked for — a live
/// heart-rate stream, a find acknowledgement, a setting changed on the band — go to `onFrame`.
@MainActor
final class BandTransport {
    weak var link: BandLink?
    /// Unsolicited frames.
    var onFrame: (([UInt8]) -> Void)?
    /// Every frame both ways, for the band's log.
    var onTraffic: ((_ outgoing: Bool, _ frame: [UInt8]) -> Void)?
    let timeout: TimeInterval

    private struct Waiting {
        let op: UInt8
        let accepts: Set<UInt8>
        let until: ([[UInt8]]) -> Bool
        var frames: [[UInt8]] = []
        let continuation: CheckedContinuation<[[UInt8]], Error>
        let deadline: Task<Void, Never>
    }

    private var waiting: Waiting?
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var running = false

    init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    var isBusy: Bool { running }

    /// Sends `request` and returns the frames that answered it. `accepts` are the opcodes that
    /// belong to the reply (the request's own by default); a reply of several frames ends when
    /// `until` is true of the frames so far — by default after the first.
    func perform(_ request: [UInt8], accepts: Set<UInt8>? = nil, timeout: TimeInterval? = nil,
                 until: @escaping ([[UInt8]]) -> Bool = { !$0.isEmpty }) async throws -> [[UInt8]] {
        await acquire()
        defer { release() }
        guard let link, link.isLinkReady else { throw BandError.notConnected }
        let op = request.first ?? 0
        let wait = timeout ?? self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.expire()
            }
            waiting = Waiting(op: op, accepts: accepts ?? [op], until: until, continuation: continuation, deadline: deadline)
            onTraffic?(true, request)
            link.send(request)
        }
    }

    /// A command whose reply (if any) arrives unsolicited.
    func send(_ request: [UInt8]) {
        guard let link, link.isLinkReady else { return }
        onTraffic?(true, request)
        link.send(request)
    }

    /// A notification from the band.
    func deliver(_ frame: [UInt8]) {
        guard let op = frame.first else { return }
        onTraffic?(false, frame)
        if var current = waiting, current.accepts.contains(op) {
            current.frames.append(frame)
            if current.until(current.frames) {
                finish(current, with: .success(current.frames))
            } else {
                waiting = current
            }
            return
        }
        onFrame?(frame)
    }

    /// The link went away: whoever is waiting is told so.
    func linkDropped() {
        if let current = waiting { finish(current, with: .failure(BandError.notConnected)) }
    }

    // MARK: Private

    private func expire() {
        guard let current = waiting else { return }
        // Part of a reply is still a reply; nothing at all is a timeout.
        if current.frames.isEmpty {
            finish(current, with: .failure(BandError.timeout(current.op)))
        } else {
            finish(current, with: .success(current.frames))
        }
    }

    private func finish(_ current: Waiting, with result: Result<[[UInt8]], Error>) {
        current.deadline.cancel()
        waiting = nil
        current.continuation.resume(with: result)
    }

    private func acquire() async {
        if !running {
            running = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            running = false
        } else {
            queue.removeFirst().resume()
        }
    }
}

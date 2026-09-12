import Foundation

/// One firmware image the app can flash: bundled with the app (Firmware/*.bin) or picked
/// by the user. `version` is the wrapper's own label (file 0x10, e.g. "RT12_3.11.00_260911").
struct RingFirmwareImage: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: [UInt8]
    let bundled: Bool

    var version: String {
        guard bytes.count > 0x30 else { return "" }
        let text = bytes[0x10..<0x30].prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self)
    }
    var preflight: RingFirmwareUpdate.Failure? { RingFirmwareUpdate.precondition(bytes) }
    var pockets: Int { RingFirmwareUpdate.pocketCount(bytes) }
    var crc16: UInt16 { RingProtocol.crc16(bytes) }

    static func load(_ url: URL, bundled: Bool) -> RingFirmwareImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return RingFirmwareImage(id: url.path, name: url.lastPathComponent, bytes: [UInt8](data), bundled: bundled)
    }

    /// The images shipped inside the app (the patched build and the stock one to roll back to).
    static func bundled() -> [RingFirmwareImage] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: "Firmware") ?? []
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { load($0, bundled: true) }
    }
}

/// Drives one firmware flash and publishes everything the screen shows: a live log, the
/// pocket count, and the final status. The protocol itself lives in `RingFirmwareUpdate`;
/// this only sequences it over the connected ring and narrates it.
@MainActor
final class RingFirmwareFlasher: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sent = 0
    @Published private(set) var total = 0
    @Published private(set) var lines: [Line] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?

    var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }

    private var task: Task<Void, Never>?

    /// Starts flashing `image` over `session`. Refuses (with a logged reason) if the image
    /// would fail the ring's own receiver checks or a flash is already running.
    func flash(_ image: RingFirmwareImage, over session: RingSession) {
        guard !phase.isRunning else { return }
        lines = []
        sent = 0
        total = image.pockets
        finishedAt = nil
        startedAt = Date()
        log("Image \(image.name) — \(image.bytes.count) bytes, \(image.pockets) pockets, crc16 \(hex16(image.crc16))")
        if let bad = image.preflight {
            phase = .failed(bad.reason)
            log("Pre-flight failed: \(bad.reason). Nothing was sent.")
            finishedAt = Date()
            return
        }
        log("Pre-flight OK: magic, model RT12_V3.1, image_id 0x2793, size, wrapper checksum")
        phase = .running
        session.log.note("Firmware flash started", image.version)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await RingFirmwareUpdate.run(
                    image: image.bytes,
                    send: { cmd, payload in
                        let replies = try await session.sendRawBigData(cmd: cmd, payload: payload)
                        self.narrate(cmd: cmd, payload: payload, replies: replies)
                        return replies
                    },
                    progress: { sent, total in
                        self.sent = sent
                        self.total = total
                    })
                self.finish(.succeeded, session: session)
            } catch let failure as RingFirmwareUpdate.Failure {
                self.finish(.failed(failure.reason), session: session)
            } catch {
                self.finish(.failed(error.localizedDescription), session: session)
            }
        }
    }

    func cancel() {
        guard phase.isRunning else { return }
        task?.cancel()
        log("Cancelled. The ring discards the partial image and keeps running the old one.")
        phase = .failed("cancelled")
        finishedAt = Date()
    }

    func clear() {
        guard !phase.isRunning else { return }
        phase = .idle; lines = []; sent = 0; total = 0; startedAt = nil; finishedAt = nil
    }

    // MARK: narration

    private func narrate(cmd: UInt8, payload: [UInt8], replies: [RingInbound]) {
        let status = replies.last(where: { $0.cmd == cmd })?.payload.first
        let ack = status.map { $0 == 0 ? "ack" : "NAK status \($0)" } ?? "no reply"
        switch cmd {
        case 1: log("start → \(ack)")
        case 2: log("init (len, crc16, checksum) → \(ack)")
        case 3:
            let seq = payload.count >= 2 ? Int(payload[0]) | (Int(payload[1]) << 8) : 0
            // one line per 8 pockets keeps the log readable; every pocket still moves the bar
            if seq == 1 || seq % 8 == 0 || seq == total || status != 0 {
                log("pocket \(seq)/\(total) (\(payload.count - 2) bytes) → \(ack)")
            }
        case 4: log("check (length) → \(ack)")
        case 5: log("end → \(ack) — ring commits and reboots into the new image")
        default: log("cmd \(cmd) → \(ack)")
        }
    }

    private func finish(_ result: Phase, session: RingSession) {
        guard phase.isRunning else { return }          // a cancel already closed it
        phase = result
        let now = Date()
        finishedAt = now
        switch result {
        case .succeeded:
            let secs = Int(now.timeIntervalSince(startedAt ?? now))
            log("✓ Flashed \(sent)/\(total) pockets in \(secs)s. The ring is rebooting; it reconnects in ~10–20 s.")
            session.log.note("Firmware flash finished", "\(sent) pockets, \(secs)s")
        case .failed(let why):
            log("✗ Failed: \(why). The ring kept its old firmware; you can retry.")
            session.log.note("Firmware flash failed", why)
        default: break
        }
    }

    private func log(_ text: String) {
        lines.append(Line(time: Date(), text: text))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }
}

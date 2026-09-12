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
        /// image sent; waiting for the ring to reboot and reconnect on the new version
        case verifying
        case succeeded
        case failed(String)

        /// The UI stays locked (no cancel, no dismiss) through both sending and verifying.
        var isRunning: Bool { self == .running || self == .verifying }
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

    /// Seconds left, from the pace so far. Nil until a few pockets have gone through.
    var estimatedRemaining: TimeInterval? {
        guard phase.isRunning, let startedAt, sent >= 3, total > sent else { return nil }
        let perPocket = Date().timeIntervalSince(startedAt) / Double(sent)
        return perPocket * Double(total - sent)
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

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
        let fromVersion = session.firmware
        session.log.note("Firmware flash started", image.version)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await RingFirmwareUpdate.run(
                    image: image.bytes,
                    send: { cmd, payload, until in
                        let replies = try await session.sendRawBigData(cmd: cmd, payload: payload, until: until)
                        self.narrate(cmd: cmd, payload: payload, replies: replies)
                        return replies
                    },
                    progress: { sent, total in
                        self.sent = sent
                        self.total = total
                    })
                await self.verify(image: image, from: fromVersion, session: session)
            } catch let failure as RingFirmwareUpdate.Failure {
                self.finish(.failed(failure.reason), session: session)
            } catch {
                self.finish(.failed(error.localizedDescription), session: session)
            }
        }
    }

    /// After the commit frame there is no ack — the ring reboots. Real success is the ring
    /// coming back on the new version, so watch the link drop then read the firmware revision.
    /// This is what turns a written-but-not-applied commit from a false "success" into the truth.
    private func verify(image: RingFirmwareImage, from: String?, session: RingSession) async {
        phase = .verifying
        log("Commit sent. Waiting for the ring to reboot and reconnect (about 15–30 s)…")
        var sawDrop = false
        var announcedDrop = false, announcedBack = false
        for _ in 0..<40 {                                   // ~80 s
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let ready = session.transport.link?.isLinkReady ?? false
            if !ready {
                sawDrop = true
                if !announcedDrop { log("Ring disconnected — it is rebooting into the new image."); announcedDrop = true }
                continue
            }
            if sawDrop && !announcedBack { log("Ring reconnected. Reading its firmware version…"); announcedBack = true }
            if sawDrop, let now = session.firmware, now != from {
                if now.contains("3.11") || image.version.contains(now) || now.contains("260911") {
                    finish(.succeeded, session: session); return
                }
                finish(.failed("rebooted but came back on \(now) — the bootloader kept the old image (version tie)"), session: session)
                return
            }
        }
        if !sawDrop {
            finish(.failed("the ring never rebooted — the commit frame was not applied by the ring"), session: session)
        } else if let now = session.firmware, now == from {
            finish(.failed("rebooted but stayed on \(now) — the bootloader kept the old image"), session: session)
        } else {
            finish(.failed("could not confirm the new version within 80 s — check 'On the ring' after it reconnects"), session: session)
        }
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
        case 5: log("end → sent. The ring commits and reboots now; the Bluetooth drop that follows is expected.")
        default: log("cmd \(cmd) → \(ack)")
        }
    }

    private func finish(_ result: Phase, session: RingSession) {
        guard phase.isRunning else { return }
        phase = result
        let now = Date()
        finishedAt = now
        switch result {
        case .succeeded:
            let secs = Int(now.timeIntervalSince(startedAt ?? now))
            log("✓ Done in \(secs)s. The ring rebooted and is now running \(session.firmware ?? "the new firmware").")
            session.log.note("Firmware flash finished", session.firmware ?? "\(sent) pockets")
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

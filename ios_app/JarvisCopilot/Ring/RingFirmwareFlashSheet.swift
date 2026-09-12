import SwiftUI

/// The flashing popup: what is being flashed, a circular progress gauge with time remaining,
/// the live log, and the final verdict. Opens when a flash starts and stays until dismissed,
/// so the outcome is never lost off-screen.
struct RingFirmwareFlashSheet: View {
    @ObservedObject var flasher: RingFirmwareFlasher
    let image: RingFirmwareImage
    let fromVersion: String?
    let onDismiss: () -> Void

    // ticks once a second so the elapsed / remaining labels move between pockets
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    gauge
                        .padding(.top, 8)
                    if flasher.phase.isRunning { lockedNotice }
                    details
                    logCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Deliberately no Cancel: once started the transfer must run to the end.
                    if !flasher.phase.isRunning {
                        Button("Done") { onDismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(flasher.phase.isRunning)
            .navigationBarBackButtonHidden(flasher.phase.isRunning)
            .onReceive(clock) { now = $0 }
        }
        .presentationDetents([.large])
    }

    private var title: String {
        switch flasher.phase {
        case .idle, .running: return "Flashing firmware"
        case .succeeded: return "Firmware flashed"
        case .failed(let why): return why == "cancelled" ? "Flash cancelled" : "Flash failed"
        }
    }

    // MARK: Gauge

    private var gauge: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: CGFloat(gaugeFraction))
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: flasher.sent)
                VStack(spacing: 2) {
                    switch flasher.phase {
                    case .succeeded:
                        Image(systemName: "checkmark").font(.system(size: 44, weight: .semibold)).foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "xmark").font(.system(size: 44, weight: .semibold)).foregroundStyle(.red)
                    default:
                        Text("\(Int(flasher.fraction * 100))%")
                            .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("\(flasher.sent) / \(flasher.total)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .frame(width: 190, height: 190)

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 28) {
                stat("Elapsed", clockText(flasher.elapsed))
                if flasher.phase.isRunning {
                    stat("Remaining", flasher.estimatedRemaining.map { "~" + clockText($0) } ?? "…")
                } else if let finished = flasher.finishedAt, let started = flasher.startedAt {
                    stat("Took", clockText(finished.timeIntervalSince(started)))
                }
            }
        }
    }

    private var lockedNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("This cannot be cancelled").font(.subheadline.weight(.semibold))
                Text("Keep the ring close to the phone and leave this screen open until it finishes. "
                     + "The ring keeps its current firmware until the whole image is verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var gaugeFraction: Double {
        flasher.phase == .succeeded ? 1 : flasher.fraction
    }

    private var gaugeColor: Color {
        switch flasher.phase {
        case .succeeded: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }

    private var statusColor: Color {
        switch flasher.phase {
        case .succeeded: return .green
        case .failed: return .red
        default: return .primary
        }
    }

    private var statusLine: String {
        switch flasher.phase {
        case .idle: return "Preparing…"
        case .running:
            if flasher.sent == 0 { return "Handshaking with the ring…" }
            if flasher.sent < flasher.total { return "Sending image to the ring. Keep the ring close to the phone." }
            return "Verifying and committing. The ring will reboot."
        case .succeeded:
            return "Image committed. The ring is rebooting into \(image.version) and reconnects in about 20 s."
        case .failed(let why):
            return "\(why). The ring kept its current firmware — you can retry."
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(spacing: 0) {
            detail("Image", image.version.isEmpty ? image.name : image.version)
            Divider().padding(.leading, 16)
            detail("From", fromVersion ?? "unknown")
            Divider().padding(.leading, 16)
            detail("To", image.version.isEmpty ? "—" : image.version)
            Divider().padding(.leading, 16)
            detail("Size", "\(image.bytes.count) bytes · \(image.pockets) pockets")
            Divider().padding(.leading, 16)
            detail("CRC-16", String(format: "0x%04X", image.crc16))
            Divider().padding(.leading, 16)
            detail("Pre-flight", image.preflight?.reason ?? "passed")
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).font(.callout.monospacedDigit()).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flash log").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(flasher.lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.time, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                            }
                            .font(.caption2.monospaced())
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: 220)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: flasher.lines.count) { _, _ in
                    if let last = flasher.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func clockText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

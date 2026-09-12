import SwiftUI
import UniformTypeIdentifiers

/// The "Firmware" card in ring settings: pick an image (bundled or a file), see its pre-flight
/// result, flash it, and watch the live log, progress bar and final status.
struct RingFirmwareSection: View {
    @ObservedObject var flasher: RingFirmwareFlasher
    let session: RingSession
    let ready: Bool
    let currentVersion: String?

    @State private var images: [RingFirmwareImage] = RingFirmwareImage.bundled()
    @State private var selectedID: String?
    @State private var confirmFlash = false
    @State private var importing = false
    @State private var importError: String?
    @State private var showSheet = false
    @State private var flashing: RingFirmwareImage?

    private var selected: RingFirmwareImage? { images.first { $0.id == selectedID } ?? images.first }

    var body: some View {
        CardGroup("Firmware") {
            Row {
                HStack {
                    Text("On the ring").foregroundStyle(.secondary)
                    Spacer()
                    Text(currentVersion ?? "—").font(.callout.monospacedDigit())
                }
            }
            RowDivider()
            Row {
                HStack {
                    Text("Image").foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(images) { image in
                            Button(image.version.isEmpty ? image.name : image.version) { selectedID = image.id }
                        }
                        Divider()
                        Button { importing = true } label: { Label("Choose a .bin file…", systemImage: "folder") }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selected.map { $0.version.isEmpty ? $0.name : $0.version } ?? "none")
                                .font(.callout.monospacedDigit())
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }
                }
            }
            if let image = selected {
                RowDivider()
                Row {
                    HStack(alignment: .top) {
                        Image(systemName: image.preflight == nil ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(image.preflight == nil ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.preflight?.reason ?? "Pre-flight OK — the ring's own receiver checks all pass")
                                .font(.caption)
                            Text("\(image.bytes.count) bytes · \(image.pockets) pockets · crc16 \(String(format: "0x%04X", image.crc16))")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            if let importError {
                RowDivider()
                Row { Text(importError).font(.caption).foregroundStyle(.orange) }
            }
            RowDivider()
            Row {
                HStack {
                    if flasher.phase.isRunning {
                        Button { showSheet = true } label: { Label("Show progress", systemImage: "gauge.with.needle") }
                    } else {
                        Button {
                            confirmFlash = true
                        } label: {
                            Label("Flash to ring", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(!ready || selected == nil || selected?.preflight != nil)
                    }
                    Spacer()
                    statusBadge
                }
            }
            if flasher.phase != .idle, !flasher.phase.isRunning {
                RowDivider()
                Row {
                    HStack {
                        Text(lastResultText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Details") { showSheet = true }.font(.caption)
                    }
                }
            }
        }
        .confirmationDialog("Flash \(selected?.version ?? "this image") to the ring?",
                            isPresented: $confirmFlash, titleVisibility: .visible) {
            Button("Flash", role: .destructive) {
                if let image = selected {
                    flashing = image
                    showSheet = true
                    flasher.flash(image, over: session)
                }
            }
        } message: {
            Text("Takes a few minutes and cannot be cancelled once started. Keep the ring close to the phone. "
                 + "The ring keeps its current firmware until the whole image is received and verified, then reboots into the new one.")
        }
        .sheet(isPresented: $showSheet) {
            if let image = flashing ?? selected {
                RingFirmwareFlashSheet(flasher: flasher, image: image, fromVersion: currentVersion) {
                    showSheet = false
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            switch result {
            case .success(let url):
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                if let image = RingFirmwareImage.load(url, bundled: false) {
                    images.removeAll { !$0.bundled }
                    images.append(image)
                    selectedID = image.id
                    importError = nil
                } else {
                    importError = "Couldn't read \(url.lastPathComponent)"
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch flasher.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Flashing \(Int(flasher.fraction * 100))%").font(.caption).monospacedDigit()
            }
        case .succeeded:
            Label("Flashed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let why):
            Label(why == "cancelled" ? "Cancelled" : "Failed", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private var lastResultText: String {
        switch flasher.phase {
        case .succeeded: return "Last flash: succeeded (\(flasher.sent) pockets, \(Int(flasher.elapsed)) s)"
        case .failed(let why): return "Last flash: \(why == "cancelled" ? "cancelled" : "failed — " + why)"
        default: return ""
        }
    }

    private func elapsed(from: Date, to: Date) -> String {
        let s = Int(to.timeIntervalSince(from))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

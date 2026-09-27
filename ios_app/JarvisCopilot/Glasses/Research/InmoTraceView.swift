import SwiftUI
import UniformTypeIdentifiers

/// Official-app evidence is imported from Apple's external diagnostics, never sniffed in-process.
struct InmoTraceView: View {
    @State private var sessions: [InmoTraceSession] = []
    @State private var selected: UUID?
    @State private var title = ""
    @State private var note = ""
    @State private var source: InmoTraceSource = .network
    @State private var importing = false
    @State private var busy = false
    @State private var failure: String?
    @State private var exportURL: URL?
    @State private var confirmDelete = false
    private let store = InmoTraceStore.shared
    private var session: InmoTraceSession? { sessions.first { $0.id == selected } }

    var body: some View {
        List {
            Section {
                Label("Imported official-app traces", systemImage: "tray.and.arrow.down")
                    .font(.headline)
                Text("Record INMO with Apple's Mac tools, then import the originals here. Jarvis does not intercept another app's traffic.")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink("How to record INMO traffic") { InmoTraceGuideView() }
            }
            Section("Sessions") {
                HStack {
                    TextField("Experiment name", text: $title)
                    Button("Create") {
                        run {
                            let created = try await store.create(title: title)
                            selected = created.id; title = ""; exportURL = nil
                            try await reload()
                        }
                    }.disabled(busy)
                }
                if !sessions.isEmpty {
                    Picker("Selected session", selection: $selected) {
                        ForEach(sessions) { item in Text(item.title).tag(Optional(item.id)) }
                    }
                    .disabled(busy)
                    .onChange(of: selected) { _, _ in exportURL = nil }
                }
            }
            if let session {
                Section("Import evidence") {
                    Picker("Recorded with", selection: $source) {
                        ForEach(InmoTraceSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button { importing = true } label: {
                        Label("Import trace files", systemImage: "doc.badge.plus")
                    }.disabled(busy)
                    Text("PCAP, PCAPNG, PacketLogger, Bluetooth snoop or helper capture.json. 256 MiB per session. Source is your label, not verified app attribution. Raw files may contain private phone traffic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Imported statistics") {
                    LabeledContent("Files", value: "\(session.attachments.count)")
                    LabeledContent("Original bytes", value: ByteCountFormatter.string(fromByteCount: Int64(session.totalBytes), countStyle: .file))
                    LabeledContent("Session created", value: session.createdAt.formatted())
                    Text("These are trace-file statistics, not live glasses telemetry. No imported file means no observed packets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Trace files") {
                    if session.attachments.isEmpty {
                        Text("No traces imported yet.").foregroundStyle(.secondary)
                    }
                    ForEach(session.attachments) { attachment in
                        NavigationLink { InmoTraceDetailView(attachment: attachment) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(attachment.originalName).lineLimit(2)
                                Text("\(attachment.summary.format) · \(attachment.byteCount.formatted()) bytes")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(attachment.summary.packetCount.map { "\($0.formatted()) container records" } ?? "External analysis required")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Actions and observations") {
                    TextField("What did you do in INMO? Include the action's time.", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    Button("Add note") {
                        run {
                            _ = try await store.addNote(note, to: session.id)
                            note = ""; exportURL = nil
                            try await reload()
                        }
                    }.disabled(busy || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Notes record when you typed them. Include the actual action time to correlate it with the capture.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(session.notes) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).textSelection(.enabled)
                            Text("Noted \(item.recordedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Export") {
                    Button("Prepare evidence ZIP") {
                        run { exportURL = try await store.export(session.id) }
                    }.disabled(busy || session.attachments.isEmpty)
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share evidence ZIP", systemImage: "square.and.arrow.up") }
                        Text("Snapshot ready. Includes unchanged originals, hashes, summaries and notes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Delete this session", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
            }
            if busy { Section { ProgressView("Processing trace files…") } }
            if let failure {
                Section("Could not complete operation") {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { self.failure = nil }
                }
            }
        }
        .navigationTitle("INMO traces")
        .navigationBarTitleDisplayMode(.inline)
        .task { run { try await reload() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard let id = selected else { return }
                let recordedSource = source
                run {
                    var errors = [String]()
                    for url in urls {
                        do { _ = try await store.importFile(url, into: id, source: recordedSource) }
                        catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                    exportURL = nil
                    try await reload()
                    if !errors.isEmpty { throw InmoTraceError.invalid(errors.joined(separator: "\n")) }
                }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .confirmationDialog("Delete this session and its imported copies?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                guard let id = selected else { return }
                run { try await store.delete(id); selected = nil; exportURL = nil; try await reload() }
            }
        } message: { Text("The original files in Files or on your Mac are kept.") }
    }

    @MainActor private func reload() async throws {
        sessions = try await store.sessions()
        if selected == nil { selected = sessions.first?.id }
    }
    @MainActor private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { failure = error.localizedDescription }
        }
    }
}

struct InmoTraceDetailView: View {
    let attachment: InmoTraceAttachment
    var body: some View {
        List {
            Section("Original evidence") {
                LabeledContent("Format", value: attachment.summary.format)
                LabeledContent("Source label", value: attachment.source.rawValue)
                LabeledContent("Bytes", value: attachment.byteCount.formatted())
                LabeledContent("Imported", value: attachment.importedAt.formatted())
                if let count = attachment.summary.packetCount { LabeledContent("Container records", value: count.formatted()) }
                if let first = attachment.summary.firstPacketAt { LabeledContent("First record", value: first.ISO8601Format()) }
                if let last = attachment.summary.lastPacketAt { LabeledContent("Last record", value: last.ISO8601Format()) }
                if !attachment.summary.linkTypes.isEmpty {
                    LabeledContent("Link types", value: attachment.summary.linkTypes.map(String.init).joined(separator: ", "))
                }
                Text(attachment.summary.notice).font(.caption).foregroundStyle(.secondary)
            }
            Section("SHA-256 · unchanged original") {
                Text(attachment.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("Raw previews") {
                ForEach(attachment.summary.previews) { packet in
                    DisclosureGroup(packet.id == 0 ? "File prefix" : "Record \(packet.id) · \(packet.byteCount) bytes") {
                        Text(packet.hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if packet.byteCount > 128 { Text("First 128 bytes; full bytes are preserved in the export.").font(.caption) }
                    }
                }
            }
        }
        .navigationTitle(attachment.originalName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InmoTraceGuideView: View {
    var body: some View {
        List {
            Section("1 · Prepare an experiment") {
                Text("Connect this iPhone to your Mac and trust it. Open INMO Global and connect your GO3. Pick one action per capture: connection startup, brightness, a photo, or a battery refresh. Record its time.")
                Text("Use the Mac's INMO capture helper from this project's inmo-re/tools folder for network capture. You do not need to jailbreak or decrypt INMO for this workflow.")
            }
            Section("2 · Network capture on the Mac") {
                Text("Run inmo_capture.py preflight, then its capture command with this iPhone's identifier. The helper uses Apple's RVI interface and tcpdump. Start recording before the INMO action; stop after it finishes.")
                Text("This records iPhone IP traffic, not Bluetooth or Wi-Fi radio frames. TLS stays encrypted. A host filter reduces unrelated traffic, but can miss a changing glasses endpoint.")
                Link("Apple: recording a packet trace", destination: URL(string: "https://developer.apple.com/documentation/network/recording-a-packet-trace")!)
            }
            Section("3 · Bluetooth capture on the Mac") {
                Text("Get PacketLogger from Apple's Additional Tools for Xcode. Install Apple's current Bluetooth logging profile on the iPhone, following the profile's instructions. Connect the phone to the Mac and use PacketLogger's iOS trace option if available. Perform the INMO action and save the trace.")
                Text("Availability and payload detail depend on your iOS build and tools. If live tracing is unavailable, follow Apple's profile instructions for collecting diagnostic logs. A successful connection alone does not prove that complete ATT payloads were recorded.")
                Link("Apple Bluetooth tools", destination: URL(string: "https://developer.apple.com/bluetooth/")!)
                Link("Apple profiles and logs", destination: URL(string: "https://developer.apple.com/feedback-assistant/profiles-and-logs/")!)
            }
            Section("4 · Import and export") {
                Text("Stop the capture, then use AirDrop or iCloud Drive to save the .pcap, .pcapng or .pklg file plus the helper’s capture.json to Files. Return to INMO traces, create a session, select its source and import. Add the action and its time. Prepare and share the evidence ZIP for analysis.")
                Text("Raw captures may contain messages, media, account details and unrelated phone traffic. Review what you share. Files remain local until you export; import does not upload them to Jarvis.")
            }
        }
        .navigationTitle("Record INMO traffic")
        .navigationBarTitleDisplayMode(.inline)
    }
}

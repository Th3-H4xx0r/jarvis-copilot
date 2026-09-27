import SwiftUI

struct InmoMediaView: View {
    @ObservedObject private var media = InmoMediaTransfer.shared
    @State private var actionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Photos & videos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                Spacer()
                Button("Refresh") { run { try await media.refresh() } }
                    .disabled(media.busy)
            }
            Text(media.statusText).font(.footnote).foregroundStyle(.secondary)
            if media.busy {
                ProgressView(value: media.progress)
                Button("Cancel download", role: .cancel) { media.cancel() }
            }
            ForEach(media.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.caption).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { run { _ = try await media.download(id: item.id) } } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download \(item.name)")
                    .disabled(media.busy)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            ForEach(media.completedURLs, id: \.self) { url in
                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up").font(.caption).lineLimit(2) }
            }
            Text("Exports preserve original files. Video audio and motion sidecars download separately; processed video export is not yet verified.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Connection details") {
                TextField("Glasses Wi-Fi address", text: $media.serverAddress)
                    .keyboardType(.decimalPad).textInputAutocapitalization(.never)
                Text("The observed address is 192.168.40.1. Keep Jarvis open during Wi-Fi transfer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = actionError { Text(error).font(.caption).foregroundStyle(.red).accessibilityLabel("Media error: \(error)") }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        actionError = nil
        Task { do { try await operation() } catch { actionError = error.localizedDescription } }
    }
}

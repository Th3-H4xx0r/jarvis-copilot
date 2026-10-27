import SwiftUI

/// The glasses page's "Photos & videos" card: the newest tiles, Save & download all, and the rest
/// of the gallery one tap away.
struct InmoMediaView: View {
    @ObservedObject private var media = InmoMediaTransfer.shared
    @ObservedObject private var gallery: InmoGallery
    @ObservedObject private var session = InmoSession.shared
    @State private var actionError: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private let shown = 6

    /// A gallery other than the shared one only for render tests.
    init(gallery: InmoGallery? = nil) { _gallery = ObservedObject(wrappedValue: gallery ?? .shared) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Photos & videos") {
                HStack(spacing: 14) {
                    Button { Task { await gallery.refresh() } } label: { JcIcon("arrow.clockwise", size: 15) }
                        .accessibilityLabel("Refresh photos and videos")
                        .disabled(media.busy || !session.isReady)
                    if gallery.entries.count > shown {
                        NavigationLink { InmoGalleryView(gallery: gallery) } label: {
                            Text("See all").font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .foregroundStyle(JcTheme.accent)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                    if !gallery.entries.isEmpty {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(gallery.entries.prefix(shown)) { InmoGalleryTile(entry: $0, gallery: gallery) }
                        }
                    }
                    if !gallery.entries.isEmpty || gallery.run != nil { InmoGallerySaveBar(gallery: gallery) }
                    if !gallery.other.isEmpty { otherFiles }
                    if let error = actionError { Text(error).font(.caption).foregroundStyle(JcTheme.danger).accessibilityLabel("Media error: \(error)") }
                }
                .tint(JcTheme.accent)
            }
        }
        .task(id: session.isReady) {
            if session.isReady, media.items.isEmpty, !media.busy { await gallery.refresh() }
        }
    }

    private var summary: String {
        let saved = gallery.entries.filter(\.saved).count
        let new = gallery.unsaved.count
        if gallery.entries.isEmpty {
            return session.isReady ? "Nothing on the glasses yet — or tap Refresh." : "Connect the glasses to see their photos and videos."
        }
        var parts: [String] = []
        if new > 0 { parts.append("\(new) new on the glasses") }
        if saved > 0 { parts.append("\(saved) in your camera roll") }
        if new > 0 { parts.append("tap one to save it") }
        return parts.joined(separator: " · ")
    }

    /// Audio recordings and anything that isn't a photo or video: download and share as before.
    private var otherFiles: some View {
        DisclosureGroup("Other files (\(gallery.other.count))") {
            ForEach(gallery.other) { item in
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
                    .disabled(media.busy || gallery.run != nil)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            ForEach(media.completedURLs, id: \.self) { url in
                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up").font(.caption).lineLimit(2) }
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        actionError = nil
        Task { do { try await operation() } catch { actionError = error.localizedDescription } }
    }
}

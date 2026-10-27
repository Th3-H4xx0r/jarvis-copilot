import SwiftUI
import UIKit

/// Every photo and video from the glasses, by day, with the same Save & download all bar.
struct InmoGalleryView: View {
    @ObservedObject private var gallery: InmoGallery
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    init(gallery: InmoGallery? = nil) { _gallery = ObservedObject(wrappedValue: gallery ?? .shared) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InmoGallerySaveBar(gallery: gallery)
                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.dayTitle(group.day)).font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.muted)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(group.entries) { InmoGalleryTile(entry: $0, gallery: gallery) }
                        }
                    }
                }
                if gallery.entries.isEmpty {
                    Text("No photos or videos from the glasses yet. Refresh with the glasses connected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(JcTheme.bg)
        .tint(JcTheme.accent)
        .navigationTitle("Glasses gallery")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await gallery.refresh() }
    }

    private var days: [(day: Date, entries: [InmoGalleryEntry])] {
        Dictionary(grouping: gallery.entries) { Calendar.current.startOfDay(for: $0.capturedAt) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

/// "Save & download all", or the running batch's progress with Cancel, and the last result.
struct InmoGallerySaveBar: View {
    @ObservedObject var gallery: InmoGallery
    @ObservedObject private var transfer = InmoMediaTransfer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let run = gallery.run {
                Text("Saving \(min(run.done + 1, run.total)) of \(run.total)…").font(.subheadline.weight(.semibold))
                ProgressView(value: min(1, (Double(run.done) + (run.current == nil ? 0 : transfer.progress)) / Double(max(run.total, 1))))
                    .tint(JcTheme.accent)
                Text(transfer.statusText + " Keep Jarvis open while saving.").font(.caption).foregroundStyle(.secondary)
                Button(role: .cancel) { gallery.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
            } else {
                let count = gallery.unsaved.count
                Button { gallery.save(keys: nil) } label: {
                    Label(count > 0 ? "Save & download all (\(count))" : "All saved to your camera roll",
                          systemImage: count > 0 ? "square.and.arrow.down.on.square" : "checkmark.circle")
                }
                .buttonStyle(.jcGlass(full: true))
                .disabled(count == 0 || transfer.busy)
            }
            if let message = gallery.message, gallery.run == nil {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One square tile: the preview (or a placeholder until it's downloaded) and its state.
struct InmoGalleryTile: View {
    let entry: InmoGalleryEntry
    @ObservedObject var gallery: InmoGallery
    @ObservedObject private var transfer = InmoMediaTransfer.shared

    /// Previews are ~400 px JPEGs: decoding one is a millisecond, and the lazy grid only builds the
    /// tiles on screen, so they load in place and are kept.
    private static let thumbnails = NSCache<NSURL, UIImage>()
    private var image: UIImage? {
        guard let url = gallery.library.thumbnailURL(entry.record) else { return nil }
        if let cached = Self.thumbnails.object(forKey: url as NSURL) { return cached }
        guard let loaded = UIImage(contentsOfFile: url.path) else { return nil }
        Self.thumbnails.setObject(loaded, forKey: url as NSURL)
        return loaded
    }

    var body: some View {
        Button(action: tap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { preview }
                .overlay(alignment: .topTrailing) { state.padding(5) }
                .overlay(alignment: .bottomLeading) { footer.padding(5) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(JcTheme.glassBorder, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.saved && (entry.item == nil || gallery.run != nil || transfer.busy))
        .accessibilityLabel(accessibility)
    }

    private var isCurrent: Bool { gallery.run?.current == entry.key }
    private var hasBadge: Bool { entry.kind == .video || entry.item == nil || entry.record?.withoutSound == true }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                JcTheme.glassFill
                VStack(spacing: 4) {
                    Image(systemName: entry.kind == .video ? "video" : "photo").font(.title3)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)).font(.caption2)
                }
                .foregroundStyle(JcTheme.muted)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if isCurrent {
            ProgressView(value: transfer.progress).progressViewStyle(.circular).tint(JcTheme.accent)
                .padding(3).background(.black.opacity(0.55), in: Circle())
        } else if entry.saved {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, JcTheme.success)
        } else if gallery.failed.contains(entry.key) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JcTheme.amber)
        }
    }

    @ViewBuilder private var footer: some View {
        if hasBadge {
            HStack(spacing: 4) {
                if entry.kind == .video {
                    Image(systemName: "video.fill")
                    if let seconds = entry.record?.duration { Text(Self.duration(seconds)) }
                }
                if entry.record?.withoutSound == true { Image(systemName: "speaker.slash.fill") }
                if entry.item == nil { Text("Not on glasses") }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var accessibility: String {
        var parts = [entry.kind == .video ? "Video" : "Photo", entry.capturedAt.formatted(date: .abbreviated, time: .shortened)]
        if entry.saved { parts.append(entry.record?.withoutSound == true ? "saved without sound" : "saved") }
        else { parts.append("tap to save to your camera roll") }
        if entry.item == nil { parts.append("not on glasses") }
        return parts.joined(separator: ", ")
    }

    private func tap() {
        if entry.saved {
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        } else {
            gallery.save(keys: [entry.key])
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

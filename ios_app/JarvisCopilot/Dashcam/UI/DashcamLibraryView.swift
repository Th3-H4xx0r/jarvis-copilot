import SwiftUI

/// Thumbnails come from the server (they need the pairing's auth headers, which AsyncImage can't send).
@MainActor
final class DashcamThumbnails {
    static let shared = DashcamThumbnails()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for clipID: String) async -> UIImage? {
        if let hit = cache.object(forKey: clipID as NSString) { return hit }
        if let task = inFlight[clipID] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let req = try? DashcamAPI().thumbURL(clipID: clipID),
                  let (data, http) = try? await JarvisAPI.shared.transport.send(req),
                  http.statusCode == 200, let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[clipID] = task
        let image = await task.value
        inFlight[clipID] = nil
        if let image { cache.setObject(image, forKey: clipID as NSString) }
        return image
    }
}

struct DashcamThumb: View {
    let clip: DashcamServerClip
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                JcIcon(clip.kind == .photo ? "photo" : "video", size: 18).foregroundStyle(JcTheme.muted)
            }
        }
        .frame(width: 84, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: clip.id) {
            if clip.hasThumb { image = await DashcamThumbnails.shared.image(for: clip.id) }
        }
    }
}

struct DashcamClipRow: View {
    let clip: DashcamServerClip
    let uploadingID: String?

    var body: some View {
        HStack(spacing: 12) {
            DashcamThumb(clip: clip)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(clip.start.formatted(date: .omitted, time: .shortened)).font(.subheadline.weight(.semibold))
                    kindBadge
                    if clip.lens != .front {
                        Text(clip.lens.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let status = DashcamClipStatus.of(clip, uploadingID: uploadingID)
                HStack(spacing: 5) {
                    JcIcon(status.symbol, size: 11).foregroundStyle(status.tint)
                    Text(status.label).font(.caption).foregroundStyle(status.tint).lineLimit(1)
                    if clip.kind != .photo && clip.durationS > 0 {
                        Text("· \(DashcamSpeed.duration(clip.durationS))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
        }
    }

    @ViewBuilder private var kindBadge: some View {
        if clip.kind != .normal {
            Text(clip.kind.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((clip.kind == .event ? JcTheme.danger : JcTheme.accent).opacity(0.2), in: Capsule())
                .foregroundStyle(clip.kind == .event ? JcTheme.danger : JcTheme.accent)
        }
    }
}

/// Every clip Jarvis knows about — on the camera, on the phone, uploading, uploaded — by day.
struct DashcamLibraryView: View {
    @StateObject private var model = DashcamLibraryModel()
    @ObservedObject private var sync: DashcamSync = .shared
    @ObservedObject private var wifi: DashcamWiFi = .shared
    @State private var confirmDelete: DashcamServerClip?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 14) {
            filters
            if let note {
                Text(note).font(.footnote).foregroundStyle(JcTheme.amber).padding(.horizontal, 20)
            }
            if let error = model.error, model.clips.isEmpty {
                CardGroup { CardEmptyBlock("Couldn't load the library: \(error)", symbol: "exclamationmark.icloud") }
            } else if model.clips.isEmpty && !model.loading {
                CardGroup { CardEmptyBlock("No clips yet. They appear after the first sync with the camera.", symbol: "film.stack") }
            }
            ForEach(model.sections) { section in
                CardGroup(section.title) {
                    ForEach(Array(section.clips.enumerated()), id: \.element.id) { i, clip in
                        if i > 0 { RowDivider() }
                        NavigationLink {
                            DashcamPlayerView(clip: clip, siblings: section.clips)
                        } label: {
                            Row(minHeight: 64) { DashcamClipRow(clip: clip, uploadingID: sync.uploading?.clipID) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { actions(for: clip) }
                    }
                }
            }
            if model.canLoadMore {
                Button("Load more") { Task { await model.loadMore() } }
                    .buttonStyle(.jcGlass(compact: true))
            } else if model.loading {
                ProgressView().padding()
            }
        }
        .task { await model.reload() }
        .refreshable { await model.reload() }
        .onChange(of: sync.lastSync) { _, _ in
            if !model.pagedBeyondFirst { Task { await model.reload() } }
        }
        .alert("Delete from the camera?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let clip = confirmDelete { Task { await deleteFromCamera(clip) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is removed from the dashcam's SD card. Copies already uploaded stay where they are.")
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DashcamLibraryModel.Filter.allCases) { f in
                    Button(f.label) { model.filter = f }
                        .buttonStyle(.jcGlass(tint: model.filter == f ? JcTheme.accent : JcTheme.muted, compact: true))
                }
                Menu {
                    Button("Both cameras") { model.lens = nil }
                    Button("Front") { model.lens = .front }
                    Button("Rear") { model.lens = .rear }
                } label: {
                    Label(model.lens?.rawValue.capitalized ?? "Both", systemImage: "camera.rotate")
                }
                .buttonStyle(.jcGlass(tint: model.lens == nil ? JcTheme.muted : JcTheme.accent, compact: true))
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func actions(for clip: DashcamServerClip) -> some View {
        if clip.onCamera && clip.phoneState != "local" && !clip.uploaded {
            Button {
                sync.pull(clip.path)
                note = wifi.onCamera ? "Pulling \(clip.name)…" : "\(clip.name) will be pulled next time the phone is on the camera's Wi‑Fi."
            } label: { Label("Pull from camera", systemImage: "arrow.down.circle") }
        }
        if clip.failed {
            Button {
                Task {
                    try? await DashcamAPI().retry(clipID: clip.id)
                    sync.kickUploads()
                    await model.reload()
                }
            } label: { Label("Retry upload", systemImage: "arrow.clockwise") }
        }
        if clip.onCamera {
            Button(role: .destructive) { confirmDelete = clip } label: { Label("Delete from camera", systemImage: "trash") }
        }
    }

    private func deleteFromCamera(_ clip: DashcamServerClip) async {
        do {
            _ = try await DashcamDevice.shared.invoke("dashcam_delete_file", args: ["path": clip.path, "confirm": true])
            note = "Deleted \(clip.name) from the camera."
            await sync.syncNow()
        } catch {
            note = error.localizedDescription
        }
    }
}

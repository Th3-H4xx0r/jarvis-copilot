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
        .task(id: "\(clip.id)/\(clip.hasThumb)") {      // a thumbnail that arrives later loads then
            if clip.hasThumb { image = await DashcamThumbnails.shared.image(for: clip.id) }
        }
    }
}

/// The one part of a row that follows live transfers — so progress redraws a line, not the list.
struct DashcamClipTransferLine: View {
    let clip: DashcamServerClip
    @ObservedObject private var sync: DashcamSync = .shared

    var body: some View {
        if let t = DashcamClipTransfer.of(clip, downloading: sync.downloading, uploading: sync.uploading) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    // An indeterminate linear bar draws as an empty track on iOS — it read as "stuck at 0%".
                    if t.spinner { ProgressView().controlSize(.mini).tint(JcTheme.accent) }
                    Text(t.fraction.map { "\(t.label) · \(Int($0 * 100))%" } ?? t.label)
                        .font(.caption2).foregroundStyle(JcTheme.accent)
                }
                if let f = t.fraction { ProgressView(value: f).tint(JcTheme.accent) }
            }
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
                let places = DashcamClipPlaces.of(clip)
                HStack(spacing: 5) {
                    place("sdcard", places.card, "On the camera's SD card")
                    place("iphone", places.phone, "On this phone")
                    place("icloud", places.cloud, "In the cloud")
                    Text(status.label).font(.caption).foregroundStyle(status.tint).lineLimit(1)
                    if clip.kind != .photo && clip.durationS > 0 {
                        Text("· \(DashcamSpeed.duration(clip.durationS))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                DashcamClipTransferLine(clip: clip)
            }
            Spacer(minLength: 0)
            JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
        }
    }

    private func place(_ symbol: String, _ on: Bool, _ label: String) -> some View {
        JcIcon(symbol, size: 11)
            .foregroundStyle(on ? JcTheme.accent : JcTheme.muted.opacity(0.35))
            .accessibilityLabel(on ? label : "Not \(label.prefix(1).lowercased() + label.dropFirst())")
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
    /// Shared, so coming back shows the last list at once while it refreshes (over LTE with uploads
    /// running, the first reply can take seconds).
    @ObservedObject private var model = DashcamLibraryModel.shared
    @ObservedObject private var sync: DashcamSync = .shared
    @ObservedObject private var wifi: DashcamWiFi = .shared
    @State private var confirmDelete: DashcamServerClip?
    @State private var note: String?
    private var selecting: Bool { get { model.selecting } nonmutating set { model.selecting = newValue } }
    private var selected: Set<String> { get { model.selected } nonmutating set { model.selected = newValue } }
    private var bulkDelete: Set<Place>? { get { model.bulkDelete } nonmutating set { model.bulkDelete = newValue } }
    @State private var openedID: String?
    @State private var deleting: (done: Int, total: Int)?
    @State private var deleteTask: Task<Void, Never>?

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
                        // Tap opens (or, while selecting, ticks); a long hold starts selecting.
                        Row(minHeight: 64) {
                            HStack(spacing: 10) {
                                if selecting {
                                    JcIcon(selected.contains(clip.id) ? "checkmark.circle.fill" : "circle", size: 20)
                                        .foregroundStyle(selected.contains(clip.id) ? JcTheme.accent : JcTheme.muted)
                                }
                                DashcamClipRow(clip: clip, uploadingID: sync.uploading?.clipID)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selecting { toggle(clip) } else { openedID = clip.id }
                        }
                        .onLongPressGesture(minimumDuration: 0.45) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            selecting = true
                            selected.insert(clip.id)
                        }
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
        .navigationDestination(item: $openedID) { id in
            if let section = model.sections.first(where: { $0.clips.contains { $0.id == id } }),
               let clip = section.clips.first(where: { $0.id == id }) {
                DashcamPlayerView(clip: clip, siblings: section.clips)
            }
        }
        .alert("Delete \(selected.count) clip\(selected.count == 1 ? "" : "s")?", isPresented: Binding(get: { bulkDelete != nil }, set: { if !$0 { bulkDelete = nil } })) {
            Button("Delete", role: .destructive) {
                let places = bulkDelete ?? []
                let clips = model.clips.filter { selected.contains($0.id) }
                deleteTask = Task { await delete(clips, places); selecting = false; selected = [] }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From " + [bulkDelete?.contains(.phone) == true ? "this phone" : nil, bulkDelete?.contains(.cloud) == true ? "the cloud" : nil,
                            bulkDelete?.contains(.camera) == true ? "the dashcam" : nil].compactMap { $0 }.joined(separator: ", ") + ". This can't be undone.")
        }
        .fullScreenCover(isPresented: Binding(get: { deleting != nil }, set: { _ in })) {
            DashcamDeletingPopup(done: deleting?.done ?? 0, total: deleting?.total ?? 0) { deleteTask?.cancel() }
                .presentationBackground(.black.opacity(0.45))
        }
        .task { await model.reload() }
        .task {
            // States move on their own (uploads, the relay to the cloud): keep the first page current.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !model.pagedBeyondFirst, sync.downloading != nil || sync.uploading != nil || sync.pendingUploads > 0 {
                    await model.reload()
                }
            }
        }
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
        let places = DashcamClipPlaces.of(clip)
        Menu {
            if places.phone {
                Button(role: .destructive) { Task { await delete(clip, [.phone]) } } label: { Label("From this phone", systemImage: "iphone") }
            }
            if places.cloud || clip.uploading {
                Button(role: .destructive) { Task { await delete(clip, [.cloud]) } } label: { Label("From the cloud", systemImage: "icloud") }
            }
            if clip.onCamera {
                Button(role: .destructive) { confirmDelete = clip } label: { Label("From the dashcam", systemImage: "sdcard") }
            }
            Button(role: .destructive) { Task { await delete(clip, [.phone, .cloud, .camera]) } } label: {
                Label("Everywhere", systemImage: "trash.fill")
            }
        } label: { Label("Delete…", systemImage: "trash") }
    }

    typealias Place = DashcamLibraryModel.Place

    private func toggle(_ clip: DashcamServerClip) {
        if selected.contains(clip.id) { selected.remove(clip.id) } else { selected.insert(clip.id) }
    }

    private func delete(_ clips: [DashcamServerClip], _ places: Set<Place>) async {
        var failed = 0, done = 0
        deleting = (0, clips.count)
        for clip in clips {
            if Task.isCancelled { break }               // Cancel stops after the clip in hand
            if !(await delete(clip, places, reload: false)) { failed += 1 }
            done += 1
            deleting = (done, clips.count)
        }
        deleting = nil
        deleteTask = nil
        let stopped = done < clips.count ? " Stopped after \(done) of \(clips.count)." : ""
        note = (failed == 0 ? "Deleted \(done) clip\(done == 1 ? "" : "s")." : "\(failed) of \(done) couldn't be deleted everywhere.") + stopped
        await model.reload()
    }

    /// Deletes the clip from the chosen places; the row's state follows on the next reload. True when every
    /// place worked.
    @discardableResult
    private func delete(_ clip: DashcamServerClip, _ places: Set<Place>, reload: Bool = true) async -> Bool {
        var done: [String] = [], failed: [String] = []
        if places.contains(.cloud) {
            do { try await DashcamAPI().deleteFromCloud(clipID: clip.id); done.append("cloud") }
            catch { failed.append("cloud: \(error.localizedDescription)") }
        }
        if places.contains(.phone) {
            let setup = DashcamSetupStore.load()
            let camera = clip.cameraID.isEmpty ? (setup?.cameraID ?? "") : clip.cameraID
            let f = DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start, durationS: clip.durationS, size: clip.size)
            try? FileManager.default.removeItem(at: sync.storage.localURL(camera: camera, file: f))
            await DashcamUploader.shared.remove(clipID: clip.id)
            try? await DashcamAPI().setPhone(clipID: clip.id, state: "deleted", error: nil)
            done.append("phone")
        }
        if places.contains(.camera), clip.onCamera {
            // Now when on the camera's Wi‑Fi, otherwise queued for the next connection — never lost.
            done.append(await sync.deleteFromCamera(clip.path) ? "dashcam" : "dashcam (when next connected)")
        }
        if places == [.phone, .cloud, .camera], failed.isEmpty {
            try? await DashcamAPI().forgetClip(clip.id)          // gone from the library too
        }
        guard reload else { return failed.isEmpty }
        note = failed.isEmpty ? "Deleted \(clip.name) from the \(done.joined(separator: ", "))."
                              : "Couldn't delete everywhere — " + failed.joined(separator: "; ")
        await model.reload()
        return failed.isEmpty
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

/// Select / Delete / Cancel, floating at the bottom right of the dashcam page over the library.
struct DashcamSelectionBar: View {
    @ObservedObject private var model = DashcamLibraryModel.shared

    var body: some View {
        HStack(spacing: 8) {
            if model.selecting {
                Text("\(model.selected.count)").font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                Menu {
                    Button(role: .destructive) { model.bulkDelete = [.phone] } label: { Label("From this phone", systemImage: "iphone") }
                    Button(role: .destructive) { model.bulkDelete = [.cloud] } label: { Label("From the cloud", systemImage: "icloud") }
                    Button(role: .destructive) { model.bulkDelete = [.camera] } label: { Label("From the dashcam", systemImage: "sdcard") }
                    Button(role: .destructive) { model.bulkDelete = [.phone, .cloud, .camera] } label: { Label("Everywhere", systemImage: "trash.fill") }
                } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                .disabled(model.selected.isEmpty)
                Button {
                    // Download again: pulled even when deleted from the phone before.
                    for clip in model.clips where model.selected.contains(clip.id) && clip.onCamera { DashcamSync.shared.pull(clip.path) }
                    model.selecting = false
                    model.selected = []
                } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(!model.clips.contains { model.selected.contains($0.id) && $0.onCamera })
                Button("Cancel") { model.selecting = false; model.selected = [] }
                    .buttonStyle(.jcGlass(compact: true))
            } else {
                Button { model.selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    .buttonStyle(.jcGlass(compact: true))
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The "deleting" popup: a ring filling clip by clip, and Cancel.
struct DashcamDeletingPopup: View {
    let done: Int
    let total: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(done) / CGFloat(total) : 0)
                    .stroke(JcTheme.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: done)
                Text(total > 0 ? "\(Int(Double(done) / Double(total) * 100))%" : "")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 84, height: 84)
            Text("Deleting \(min(done + 1, total)) of \(total)").font(.callout)
            Button("Cancel", role: .cancel, action: cancel).buttonStyle(.jcGlass(compact: true))
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

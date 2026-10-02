import AVKit
import SwiftUI

@MainActor
final class DashcamPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var photo: UIImage?
    @Published private(set) var fixes: [DashcamFix] = []
    @Published private(set) var current: DashcamFix?
    @Published private(set) var source = ""
    @Published private(set) var error: String?
    @Published private(set) var progress: Double?
    @Published private(set) var destinations: [(name: String, state: String, error: String?)] = []
    @Published var clip: DashcamServerClip
    private var observer: Any?
    var api = DashcamAPI()

    init(clip: DashcamServerClip) { self.clip = clip }

    var file: DashcamFile {
        DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start, durationS: clip.durationS, size: clip.size)
    }

    private var generation = 0

    func load(seekTo offset: Double? = nil) async {
        stop()
        error = nil
        generation += 1
        let mine = generation, target = clip.id
        // A newer load (Previous/Next) supersedes this one: never let a slow reply put the old clip back.
        func stale() -> Bool { mine != generation || Task.isCancelled }
        fixes = []
        destinations = []
        if let detail = try? await api.clip(target), !stale() {
            clip = detail.clip
            fixes = detail.fixes.sorted { $0.t < $1.t }
        }
        if let full = try? await api.api.get(DashcamAPI.prefix + "/clips/\(target)").object(), !stale(),
           let rows = full["destinations"] as? [[String: Any]] {
            func text(_ v: Any?) -> String? { v.flatMap { $0 is NSNull ? nil : "\($0)" } }
            destinations = rows.map { (text($0["name"]) ?? text($0["id"]) ?? "Removed destination",
                                       text($0["state"]) ?? "pending", text($0["error"])) }
        }
        guard !stale() else { return }
        let setup = DashcamSetupStore.load()
        let cameraID = DashcamSync.shared.info?.id ?? setup?.cameraID ?? clip.cameraID
        let local = DashcamSync.shared.storage.localURL(camera: cameraID, file: file)
        if clip.kind == .photo {
            if let data = try? Data(contentsOf: local) {
                photo = UIImage(data: data); source = "On this phone"
            } else if let req = try? api.api.request("GET", DashcamAPI.prefix + "/clips/\(clip.id)/stream"),
                      let (data, http) = try? await api.api.transport.send(req), http.statusCode == 200 {
                photo = UIImage(data: data); source = "From the server"
            } else {
                photo = await DashcamThumbnails.shared.image(for: clip.id)
                source = photo == nil ? "" : "Preview from the camera"
            }
            if photo == nil { error = "The photo hasn't been uploaded yet." }
            return
        }
        let item: AVPlayerItem
        let sync = DashcamSync.shared
        let onCamera = DashcamWiFi.shared.onCamera
        if !FileManager.default.fileExists(atPath: local.path), onCamera, DashcamPlayable.needsRemux(local) {
            // AVPlayer can't stream a camera's .ts: pull it to the phone (the sync's safe path), then play.
            guard await pullFromCamera(cameraID: cameraID, stale: stale) else {
                if !stale() && error == nil {
                    error = "Couldn't pull this clip from the camera. Stay on its Wi‑Fi and try again."
                }
                return
            }
        }
        if FileManager.default.fileExists(atPath: local.path) {
            source = DashcamPlayable.needsRemux(local) ? "Preparing the clip…" : "On this phone"
            do {
                let ready = try await DashcamPlayable.prepare(local)
                guard !stale() else { return }
                if let made = ready.made { adoptFixes(made, cameraID: cameraID) }
                item = AVPlayerItem(url: ready.url)
                source = "On this phone"
            } catch {
                guard !stale() else { return }
                source = ""
                self.error = "This clip couldn't be prepared for playback: \(error.localizedDescription)"
                return
            }
        } else if onCamera, let setup, let cam = sync.cameraFactory(setup) {
            item = AVPlayerItem(url: cam.fileURL(file))       // MP4 cameras stream as they are
            source = "Straight from the camera"
        } else if clip.uploaded || clip.uploadState == "staged" || clip.uploadState == "done",
                  let asset = try? api.streamAsset(clipID: clip.id) {
            item = AVPlayerItem(asset: asset)
            source = "Streaming from your uploads"
        } else {
            error = clip.onCamera
                ? "Not on the phone yet. Join the camera's Wi‑Fi to pull and play it, or wait for the next sync."
                : "This clip isn't on the phone, the camera or any upload destination."
            return
        }
        guard !stale() else { return }
        let p = AVPlayer(playerItem: item)
        let start = clip.start.timeIntervalSince1970
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.current = DashcamTrack.fix(at: start + time.seconds, in: self.fixes)
            }
        }
        player = p
        if let offset { await p.seek(to: CMTime(seconds: offset, preferredTimescale: 600)) }
        current = DashcamTrack.fix(at: start + (offset ?? 0), in: fixes)
        p.play()
    }

    /// Asks the sync to pull this clip (it handles playback mode and recording safely) and waits for it.
    private func pullFromCamera(cameraID: String, stale: () -> Bool) async -> Bool {
        let sync = DashcamSync.shared
        sync.pull(clip.path)
        source = "Pulling it from the camera…"
        progress = 0
        defer { progress = nil }
        let started = Date()
        while !stale() {
            if sync.storage.exists(camera: cameraID, file: file) { return true }
            guard DashcamWiFi.shared.onCamera else { error = "Left the camera's Wi‑Fi before the clip arrived."; return false }
            if let d = sync.downloading, d.name == file.name, d.total > 0 {
                progress = Double(d.done) / Double(d.total)
                source = "Pulling it from the camera… \(Int((progress ?? 0) * 100))%"
            } else if let d = sync.downloading, d.name != file.name {
                source = "Pulling it from the camera… (after \(d.name))"
            } else if case .waitingForPark = sync.phase {
                source = "The camera only hands over clips while the car is parked."
            }
            // Nothing moving for a few minutes (camera gone quiet, clip deleted): give up.
            if sync.downloading == nil, Date().timeIntervalSince(started) > 300 { return false }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    /// GPS read from the clip itself, for clips the server has no track for yet; shared with the server too.
    private func adoptFixes(_ made: DashcamRemux.Result, cameraID: String) {
        guard fixes.isEmpty, !made.fixes.isEmpty else { return }
        let aligned = DashcamGPS.align(made.fixes, clipStart: clip.start, duration: made.duration,
                                       tzOffset: TimeZone.current.secondsFromGMT(for: clip.start))
        fixes = aligned.sorted { $0.t < $1.t }
        let id = clip.id
        Task { try? await DashcamAPI().putFixes(clipID: id, fixes: aligned) }
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        photo = nil
    }
}

/// One clip: video (or photo) with speed + heading over it and a map that follows along.
struct DashcamPlayerView: View {
    @StateObject private var model: DashcamPlayerModel
    let siblings: [DashcamServerClip]
    var startOffset: Double?

    init(clip: DashcamServerClip, siblings: [DashcamServerClip] = [], startOffset: Double? = nil) {
        _model = StateObject(wrappedValue: DashcamPlayerModel(clip: clip))
        self.siblings = siblings
        self.startOffset = startOffset
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                media
                if !model.source.isEmpty {
                    Text(model.source).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    CardGroup { CardEmptyBlock(error, symbol: "film") }
                }
                if model.fixes.count >= 2 { map }
                details
                navigation
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(model.clip.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(seekTo: startOffset) }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var media: some View {
        ZStack(alignment: .topLeading) {
            if let player = model.player {
                VideoPlayer(player: player)
            } else if let photo = model.photo {
                Image(uiImage: photo).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
                    .overlay {
                        if model.error == nil {
                            if let p = model.progress {
                                ProgressView(value: p).tint(JcTheme.accent).padding(.horizontal, 40)
                            } else {
                                ProgressView()
                            }
                        }
                    }
            }
            if model.clip.kind != .photo, let fix = model.current {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(DashcamSpeed.text(fix.speed)).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        Text("mph").font(.caption.weight(.semibold))
                    }
                    if let dir = DashcamSpeed.compass(fix.heading) {
                        Text(dir).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var map: some View {
        let points = model.fixes.map { RoutePoint(t: $0.t, lat: $0.lat, lon: $0.lon, speed: $0.speed) }
        return RouteMapView(segments: [points], revision: model.fixes.count, style: .current,
                            colors: [model.fixes.map { DashcamSpeed.color($0.speed) }],
                            markers: [], scrub: model.current.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                            fitToken: 0, interactive: true)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
    }

    private var details: some View {
        CardGroup("Clip") {
            row("Kind", model.clip.kind.label + (model.clip.lens == .front ? "" : " · \(model.clip.lens.rawValue.capitalized) camera"))
            RowDivider()
            row("Size", ByteCountFormatter.string(fromByteCount: model.clip.size, countStyle: .file))
            if let top = model.fixes.compactMap(\.speed).max() {
                RowDivider()
                row("Top speed", "\(DashcamSpeed.text(top)) mph")
            }
            ForEach(model.destinations.indices, id: \.self) { i in
                RowDivider()
                let d = model.destinations[i]
                row(d.name, d.state == "done" ? "Uploaded" : (d.error.map { "Failed: \($0)" } ?? d.state.capitalized))
            }
            RowDivider()
            row("On camera", model.clip.path)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        Row {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing).lineLimit(2).font(.callout)
            }
        }
    }

    @ViewBuilder private var navigation: some View {
        let ordered = siblings.sorted { $0.start < $1.start }
        if let i = ordered.firstIndex(where: { $0.id == model.clip.id }), ordered.count > 1 {
            HStack {
                Button { switchTo(ordered[i - 1]) } label: { Label("Previous", systemImage: "backward.end") }
                    .disabled(i == 0)
                Spacer()
                Button { switchTo(ordered[i + 1]) } label: { Label("Next", systemImage: "forward.end") }
                    .disabled(i >= ordered.count - 1)
            }
            .buttonStyle(.jcGlass(compact: true))
            .padding(.horizontal, 20)
        }
    }

    private func switchTo(_ clip: DashcamServerClip) {
        model.clip = clip
        Task { await model.load() }
    }
}

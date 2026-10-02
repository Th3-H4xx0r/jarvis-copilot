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
        if FileManager.default.fileExists(atPath: local.path) {
            item = AVPlayerItem(url: local)
            source = "On this phone"
        } else if DashcamWiFi.shared.onCamera, let setup, let cam = DashcamSync.shared.cameraFactory(setup) {
            item = AVPlayerItem(url: cam.fileURL(file))
            source = "Straight from the camera"
        } else if clip.uploaded || clip.uploadState == "staged" || clip.uploadState == "done",
                  let asset = try? api.streamAsset(clipID: clip.id) {
            item = AVPlayerItem(asset: asset)
            source = "Streaming from your uploads"
        } else {
            error = clip.onCamera
                ? "Not on the phone yet. Pull it from the camera (long-press it in the library) or wait for the next sync."
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
                    .overlay { if model.error == nil { ProgressView() } }
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

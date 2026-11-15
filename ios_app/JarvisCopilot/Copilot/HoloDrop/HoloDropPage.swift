import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Opens the in-app Orbit from anywhere (one-tap entries, the screen shortcut, the page).
@MainActor
final class HoloLauncher: ObservableObject {
    static let shared = HoloLauncher()
    private weak var presented: UIViewController?

    /// One tap from anywhere: the Orbit, already holding the newest photo or screenshot (switch it
    /// from the tray at the top), ready to throw.
    func openQuick() {
        Task {
            let item = await HoloQuickPick.newestPhoto() ?? .text("")
            present(item, tray: true)
        }
    }

    func present(_ item: HoloItem, guessFrom screenshot: URL? = nil, tray: Bool = false) {
        guard PowerState.shared.isOn("holo-drop") else { return }
        guard let client = HoloDropReceiver.shared.client else { return }
        presented?.dismiss(animated: false)
        let model = HoloOrbitModel(item: item, client: client)
        let host = UIHostingController(rootView: HoloAppOrbit(model: model, guessFrom: screenshot, tray: tray) { [weak self] in
            self?.presented?.dismiss(animated: true)
        })
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .black
        presented = host
        presentWhenReady(host)
    }

    /// Present once nothing else is mid-animation: right after a photo picker or file browser
    /// closes, presenting on the closing screen is silently dropped by UIKit (the "picked a
    /// photo and nothing happened" bug). A cold launch from Back Tap waits for the scene.
    private func presentWhenReady(_ vc: UIViewController, attempt: Int = 0) {
        guard let top = HoloQuickLook.topController(), !top.isBeingDismissed, !top.isBeingPresented,
              top.transitionCoordinator == nil, top.view.window != nil else {
            if attempt < 40 {
                Task { try? await Task.sleep(for: .milliseconds(100)); presentWhenReady(vc, attempt: attempt + 1) }
            }
            return
        }
        top.present(vc, animated: true)
    }

    /// The Holo Drop page (saved items, arrival default, Back Tap setup).
    func openPage() {
        let host = UIHostingController(rootView: NavigationStack { HoloDropPage() })
        host.view.backgroundColor = .black
        presentWhenReady(host)
    }
}

/// What a one-tap Holo Drop starts with, and the tray's sources.
@MainActor
enum HoloQuickPick {
    /// The newest photo or video in the library (a screenshot just taken included), as a file.
    static func newestPhoto() async -> HoloItem? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: opts).firstObject else { return nil }
        return await export(asset)
    }

    /// The asset's original file, streamed to Holo Drop's temp folder (never into memory).
    static func export(_ asset: PHAsset) async -> HoloItem? {
        let video = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { video ? ($0.type == .video || $0.type == .fullSizeVideo)
                                                       : ($0.type == .photo || $0.type == .fullSizePhoto) })
                ?? resources.first else { return nil }
        let dir = HoloTemp.root.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(HoloArrival.safeName(res.originalFilename))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true                 // iCloud Photos originals
        do { try await PHAssetResourceManager.default().writeData(for: res, toFile: dest, options: options) } catch { return nil }
        let mime = UTType(res.uniformTypeIdentifier)?.preferredMIMEType ?? (video ? "video/quicktime" : "image/jpeg")
        return .file(dest, name: dest.lastPathComponent, mime: mime, kind: video ? "video" : "image")
    }

    /// What's on the clipboard (reading it may show iOS's paste prompt, so only on a tap).
    static func clipboard() -> HoloItem? {
        let pb = UIPasteboard.general
        if let url = pb.url, url.scheme?.hasPrefix("http") == true { return .link(url, title: nil) }
        if let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if let url = URL(string: s), url.scheme?.hasPrefix("http") == true { return .link(url, title: nil) }
            return .text(s)
        }
        if let image = pb.image, let data = image.pngData() {
            let dir = HoloTemp.root.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Copied image.png")
            if (try? data.write(to: url)) != nil { return .file(url, name: "Copied image.png", mime: "image/png", kind: "image") }
        }
        return nil
    }

    static func file(_ picked: URL) -> HoloItem? {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dir = HoloTemp.root.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(picked.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: picked, to: copy)) != nil else { return nil }
        let type = UTType(filenameExtension: copy.pathExtension)
        let kind = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : "file"
        return .file(copy, name: copy.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream", kind: kind)
    }

    static func photo(_ item: PhotosPickerItem) async -> HoloItem? {
        let type = item.supportedContentTypes.first ?? .jpeg
        guard let picked = try? await item.loadTransferable(type: HoloPickedFile.self) else { return nil }
        let isVideo = type.conforms(to: .movie)
        return .file(picked.url, name: picked.url.lastPathComponent,
                     mime: type.preferredMIMEType ?? "application/octet-stream", kind: isVideo ? "video" : "image")
    }
}

/// The Orbit inside the app: everything the share sheet has, plus live sensing (UWB, look,
/// listen, nearest) and the screenshot's best-guess link.
struct HoloAppOrbit: View {
    @ObservedObject var model: HoloOrbitModel
    let guessFrom: URL?
    var tray = false
    let close: () -> Void
    @State private var trayPhoto: PhotosPickerItem?
    @State private var trayFiles = false
    @ObservedObject private var sensing = HoloSensing.shared
    @ObservedObject private var look = HoloLook.shared
    @State private var began = false
    @State private var note: String?
    @State private var guessTitle: String?

    var body: some View {
        ZStack(alignment: .top) {
            HoloOrbitView(model: model)
            HStack(alignment: .top) {
                if model.phase == .choosing, !macs.isEmpty { locateMenu }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.1)))
                }
                .accessibilityLabel("Close")
            }
            .padding(14)
            VStack(spacing: 8) {
                Spacer().frame(height: 64)
                if tray, model.phase == .choosing { trayRow }
                if look.running {
                    HoloCameraPreview(session: look.session)
                        .frame(width: 150, height: 200).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.3)))
                }
                if let line = sensing.busy ?? note {
                    Text(line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                Spacer()
                if let guessTitle, model.extra != nil, model.phase == .choosing {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.system(size: 11))
                        Text("Also sending · \(guessTitle) (best guess)").font(.system(size: 11)).lineLimit(1)
                        Button { model.extra = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .accessibilityLabel("Don't send the guessed link")
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .padding(.bottom, 120)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: model.phase) { _, phase in
            if phase == .choosing, !began {
                began = true
                sensing.begin(devices: model.devices) { [weak model] in model?.heading }
            }
        }
        .onReceive(sensing.$live) { model.applyLive($0, nearest: sensing.nearest) }
        .onReceive(sensing.$nearest) { model.applyLive(sensing.live, nearest: $0) }
        .onChange(of: model.settled) { _, settled in
            if settled { DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { close() } }
        }
        .task { await guessLink() }
        .onDisappear { sensing.end() }
    }

    private var macs: [HoloDevice] { model.devices.filter { $0.kind == "mac" && $0.online } }

    /// Switch what's being dropped without leaving the popup.
    private var trayRow: some View {
        HStack(spacing: 10) {
            trayTile("photo.on.rectangle", "Latest") {
                Task { if let item = await HoloQuickPick.newestPhoto() { model.item = item } }
            }
            PhotosPicker(selection: $trayPhoto, matching: .any(of: [.images, .videos])) {
                trayLabel("photo.stack", "Photos")
            }
            trayTile("doc.on.clipboard", "Clipboard") {
                if let item = HoloQuickPick.clipboard() { model.item = item } else { note = "Nothing copied" }
            }
            trayTile("folder", "Files") { trayFiles = true }
        }
        .onChange(of: trayPhoto) { _, picked in
            guard let picked else { return }
            Task {
                if let item = await HoloQuickPick.photo(picked) { model.item = item }
                trayPhoto = nil
            }
        }
        .fileImporter(isPresented: $trayFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result, let item = HoloQuickPick.file(url) { model.item = item }
        }
    }

    private func trayTile(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { trayLabel(symbol, title) }.buttonStyle(.plain)
    }

    private func trayLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 52, height: 40).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var locateMenu: some View {
        Menu {
            ForEach(macs) { mac in
                Button { Task { note = await sensing.look(mac) } } label: {
                    Label("Look at \(mac.name)", systemImage: "camera.viewfinder")
                }
                Button { Task { note = await sensing.hear(mac) } } label: {
                    Label("Listen for \(mac.name)", systemImage: "waveform")
                }
            }
        } label: {
            Label("Locate", systemImage: "location.viewfinder")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12).frame(height: 34)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .disabled(sensing.busy != nil)
    }

    /// The screenshot's web page, when the server recognises one (domain + title search).
    private func guessLink() async {
        guard let guessFrom, let data = try? Data(contentsOf: guessFrom),
              let o = try? await model.client.screenGuess(data),
              let s = o["url"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return }
        let title = o["title"] as? String ?? url.host ?? s
        guessTitle = title
        model.extra = .link(url, title: "\(title) (best guess)")
    }
}

/// The camera's picture while looking for the Mac, so he can point at it.
struct HoloCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Holo Drop's page on the iPhone (Integrations → Holo Drop → Open): drop something now,
/// what you saved, and how to set up Back Tap / the Control Center button.
struct HoloDropPage: View {
    @ObservedObject private var saved = HoloSavedList.shared
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var problem: String?
    @State private var arrival: HoloAction = .save

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                JcSectionLabel("When something arrives here", first: true) { EmptyView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(HoloAction.allCases) { a in
                            Button { setArrival(a) } label: {
                                Text(a.label).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(arrival == a ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(arrival == a ? Color.white : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button { HoloLauncher.shared.openQuick() } label: {
                    Label("Holo Drop something", systemImage: "hand.point.up.braille.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                JcSectionLabel("Drop something") { EmptyView() }
                GlassGroup {
                    PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                        GlassRow(symbol: "photo.on.rectangle", title: "Photo or video") { chevron }
                    }
                    .buttonStyle(.plain)
                    GlassRow(symbol: "doc", title: "File", action: { importing = true }) { chevron }
                    GlassRow(symbol: "doc.on.clipboard", title: "What's on the clipboard",
                             subtitle: clipboardHint, last: true, action: dropClipboard) { chevron }
                }
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }

                JcSectionLabel("Saved") { EmptyView() }
                if saved.items.isEmpty {
                    Text("Links and text you save from a drop land here. Files go to Files → Jarvis → Holo Drop; photos to Photos.")
                        .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                } else {
                    GlassGroup {
                        ForEach(Array(saved.items.prefix(50).enumerated()), id: \.element.id) { i, e in
                            GlassRow(symbol: e.kind == "link" ? "link" : "text.alignleft",
                                     title: e.kind == "link" ? (e.title.isEmpty ? e.url : e.title) : e.text,
                                     subtitle: "From \(e.from) · \(e.at.formatted(.relative(presentation: .named)))",
                                     last: i == min(49, saved.items.count - 1),
                                     action: { use(e) }) {
                                Button { saved.remove(e.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove")
                            }
                        }
                    }
                }

                JcSectionLabel("Back Tap: drop what's on screen") { EmptyView() }
                Button(action: addShortcut) {
                    Text("Add the Holo Drop Screen shortcut").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Tap above, then Shortcuts → Add (replace any old one).")
                    Text("2. Settings → Accessibility → Touch → Back Tap → Double Tap → Holo Drop Screen.")
                    Text("Then double-tap the back of the phone on anything and throw it. The Control Center control and the app icon (press and hold) open Holo Drop too.")
                }
                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .jcPageChrome("Holo Drop")
        .onAppear { arrival = currentArrival() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { dropFile(url) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await dropPhoto(item) }
        }
    }

    /// Hands the signed "Holo Drop Screen" shortcut (Take Screenshot → Holo Drop) to Shortcuts.
    private func addShortcut() {
        let url = HoloTemp.root.appendingPathComponent("\(HoloShortcutFile.name).shortcut")
        try? FileManager.default.createDirectory(at: HoloTemp.root, withIntermediateDirectories: true)
        guard (try? HoloShortcutFile.data.write(to: url)) != nil, let top = HoloQuickLook.topController() else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = top.view
        top.present(share, animated: true)
    }

    private var defaultsJSON: String {
        if case .text(let t) = PowerState.shared.row("holo-drop")?.settings["defaults"] { return t }
        return ""
    }

    private func currentArrival() -> HoloAction {
        guard let me = HoloSensing.shared.myDeviceID else { return .save }
        return HoloDefaults.action(json: defaultsJSON, device: me, fallback: .save)
    }

    /// This device's arrival default (the server applies it to every drop sent here).
    private func setArrival(_ a: HoloAction) {
        guard let me = HoloSensing.shared.myDeviceID else {
            problem = "Connect to Jarvis once, then pick this."
            return
        }
        let previous = arrival
        arrival = a
        Task {
            let result = await PowerState.shared.setSettings("holo-drop", ["defaults": HoloDefaults.merge(json: defaultsJSON, device: me, action: a)])
            if case .failed(let why) = result { arrival = previous; problem = why }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
    }

    private var clipboardHint: String {
        UIPasteboard.general.hasURLs ? "A link" : UIPasteboard.general.hasStrings ? "Text" :
            UIPasteboard.general.hasImages ? "An image" : "Nothing copied"
    }

    private func dropClipboard() {
        guard let item = HoloQuickPick.clipboard() else { problem = "Nothing on the clipboard to drop."; return }
        HoloLauncher.shared.present(item)
    }

    private func dropFile(_ picked: URL) {
        guard let item = HoloQuickPick.file(picked) else { problem = "Couldn't read that file."; return }
        HoloLauncher.shared.present(item)
    }

    private func dropPhoto(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let drop = await HoloQuickPick.photo(item) else { problem = "Couldn't load that from Photos."; return }
        HoloLauncher.shared.present(drop)
    }

    private func use(_ e: HoloSavedList.Entry) {
        if e.kind == "link", let url = URL(string: e.url), url.scheme?.hasPrefix("http") == true {
            UIApplication.shared.open(url)
        } else {
            UIPasteboard.general.string = e.text.isEmpty ? e.url : e.text
            problem = "Copied."
        }
    }
}

/// A Photos pick as a file in Holo Drop's temp folder (streamed by the system, not loaded into memory).
struct HoloPickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = HoloTemp.root.appendingPathComponent("out-\(UUID().uuidString.prefix(6))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return HoloPickedFile(url: dest)
        }
    }
}

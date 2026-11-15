import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Opens the in-app Orbit from anywhere (the screen intent, the page, a pasted link).
@MainActor
final class HoloLauncher: ObservableObject {
    static let shared = HoloLauncher()
    private weak var presented: UIViewController?

    func present(_ item: HoloItem, guessFrom screenshot: URL? = nil, attempt: Int = 0) {
        guard let client = HoloDropReceiver.shared.client else { return }
        // A cold launch from Back Tap: the scene may not be up yet.
        guard let top = HoloQuickLook.topController() else {
            if attempt < 20 {
                Task { try? await Task.sleep(for: .milliseconds(150)); present(item, guessFrom: screenshot, attempt: attempt + 1) }
            }
            return
        }
        presented?.dismiss(animated: false)
        let model = HoloOrbitModel(item: item, client: client)
        let host = UIHostingController(rootView: HoloAppOrbit(model: model, guessFrom: screenshot) { [weak self] in
            self?.presented?.dismiss(animated: true)
        })
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .black
        presented = host
        (HoloQuickLook.topController() ?? top).present(host, animated: true)
    }

    /// The Holo Drop page over whatever is open (Siri/Shortcuts "Open Holo Drop").
    func openPage(attempt: Int = 0) {
        guard let top = HoloQuickLook.topController() else {
            if attempt < 20 { Task { try? await Task.sleep(for: .milliseconds(150)); openPage(attempt: attempt + 1) } }
            return
        }
        let host = UIHostingController(rootView: NavigationStack { HoloDropPage() })
        host.view.backgroundColor = .black
        top.present(host, animated: true)
    }
}

/// The Orbit inside the app: everything the share sheet has, plus live sensing (UWB, look,
/// listen, nearest) and the screenshot's best-guess link.
struct HoloAppOrbit: View {
    @ObservedObject var model: HoloOrbitModel
    let guessFrom: URL?
    let close: () -> Void
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

                JcSectionLabel("Without the share sheet") { EmptyView() }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Back Tap or your Control Center button can drop whatever's on screen:")
                    Text("1. In Shortcuts, make a shortcut: Take Screenshot → Holo Drop Screen.")
                    Text("2. Settings → Accessibility → Touch → Back Tap → Double Tap → that shortcut.")
                    Text("3. Or pick it for a Control Center button.")
                }
                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                Button {
                    if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) }
                } label: {
                    Text("Open Shortcuts").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
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
        let pb = UIPasteboard.general
        if let url = pb.url, url.scheme?.hasPrefix("http") == true {
            HoloLauncher.shared.present(.link(url, title: nil))
        } else if let s = pb.string, !s.isEmpty {
            if let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                HoloLauncher.shared.present(.link(url, title: nil))
            } else {
                HoloLauncher.shared.present(.text(s))
            }
        } else if let image = pb.image, let data = image.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Copied image.png")
            if (try? data.write(to: url)) != nil {
                HoloLauncher.shared.present(.file(url, name: "Copied image.png", mime: "image/png", kind: "image"))
            }
        } else {
            problem = "Nothing on the clipboard to drop."
        }
    }

    private func dropFile(_ picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop/out-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(picked.lastPathComponent)
        do { try FileManager.default.copyItem(at: picked, to: copy) } catch {
            problem = "Couldn't read that file."
            return
        }
        let type = UTType(filenameExtension: copy.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : "file"
        HoloLauncher.shared.present(.file(copy, name: copy.lastPathComponent, mime: mime, kind: kind))
    }

    private func dropPhoto(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        let type = item.supportedContentTypes.first ?? .jpeg
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = "Couldn't load that from Photos."
            return
        }
        let isVideo = type.conforms(to: .movie)
        let ext = type.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let name = "\(isVideo ? "Video" : "Photo") \(Date().formatted(.dateTime.month().day().hour().minute())).\(ext)"
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? data.write(to: url)) != nil else { return }
        HoloLauncher.shared.present(.file(url, name: name, mime: type.preferredMIMEType ?? "application/octet-stream",
                                          kind: isVideo ? "video" : "image"))
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

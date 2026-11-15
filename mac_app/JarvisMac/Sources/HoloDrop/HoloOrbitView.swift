import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Mac's Orbit popup (layout A of .superpowers/brainstorm/*/content/holo-drop-popup.html):
// the item floats in the middle, his devices sit on a ring around it, the nearest one lit;
// click a device or fling the item toward one; the action chips pick what happens on arrival.
// Black and white: only the chosen chip is filled. Compiled into the app AND the Share extension.

@MainActor
@Observable
final class HoloOrbitModel {
    enum Phase: Equatable {
        case choosing
        case sending(String)
        case waiting(String)
        case landed(String)
        case failed(String)
        case off
        case unavailable(String)
    }

    var item: HoloItem?
    var devices: [HoloDevice] = []
    var loading = true
    /// The chip he picked for this drop; nil = the device's own default.
    var override: HoloAction?
    /// Lit: hovered, aimed at mid-drag, or the nearest.
    var aimed: String?
    var phase: Phase = .choosing
    var thumbnail: NSImage?

    @ObservationIgnored var onSend: ((HoloDevice, HoloAction) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onRetry: (() -> Void)?

    var nearest: HoloDevice? { HoloOrbitLayout.nearest(devices) }
    var hot: HoloDevice? { devices.first { $0.id == aimed } ?? nearest }
    var action: HoloAction { override ?? hot?.defaultAction ?? .open }
    var busy: Bool {
        if case .sending = phase { return true }
        return false
    }

    /// Devices that can take this item (glasses and Pod take text and links only).
    var targets: [HoloDevice] {
        guard let item else { return devices }
        return devices.filter { d in item.kinds.allSatisfy { d.accepts($0) } }
    }

    func choose(_ device: HoloDevice) {
        guard item != nil, !busy else { return }
        aimed = device.id
        onSend?(device, override ?? device.defaultAction)
    }

    func setItem(_ item: HoloItem?) {
        self.item = item
        thumbnail = nil
        if case .files(let urls) = item, let first = urls.first, HoloKind.forFile(first) == .image {
            Task.detached(priority: .userInitiated) {
                let image = NSImage(contentsOf: first)
                await MainActor.run { [weak self] in if self?.item == item { self?.thumbnail = image } }
            }
        }
    }
}

struct HoloOrbitView: View {
    @Bindable var model: HoloOrbitModel
    @State private var drag: CGSize = .zero
    @State private var dropTargeted = false

    static let size = CGSize(width: 400, height: 520)
    private let ringRadius: CGFloat = 138
    private var centre: CGPoint { CGPoint(x: Self.size.width / 2, y: 248) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(white: 0.02).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(dropTargeted ? 0.6 : 0.12), lineWidth: 1))
            header
            ring
            itemCard
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onDrop(of: [.fileURL, .url, .image, .movie, .plainText], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                if let item = await HoloItemLoader.load(providers) { model.setItem(item) }
            }
            return true
        }
        .onExitCommand { model.onClose?() }
    }

    private var header: some View {
        VStack {
            HStack {
                Spacer().frame(width: 28)
                Spacer()
                Text("HOLO DROP")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                .help("Close (Esc)")
            }
            .padding(.horizontal, 16).padding(.top, 16)
            Spacer()
        }
    }

    // MARK: the ring

    private var ring: some View {
        let devices = model.targets
        let positions = HoloOrbitLayout.positions(devices, centre: centre, radius: ringRadius)
        return ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
                .position(centre)
            if model.loading && devices.isEmpty {
                Text("Finding your devices…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .position(x: centre.x, y: centre.y - ringRadius)
            } else if devices.isEmpty && model.phase == .choosing {
                Text("No device can take this right now").font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .position(x: centre.x, y: centre.y - ringRadius)
            }
            ForEach(devices) { d in
                if let p = positions[d.id] {
                    bubble(d).position(x: p.x, y: p.y + 10)
                }
            }
        }
    }

    private func bubble(_ d: HoloDevice) -> some View {
        let hot = model.hot?.id == d.id
        return Button { model.choose(d) } label: {
            VStack(spacing: 6) {
                Image(systemName: d.symbol).font(.system(size: 19, weight: .regular))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(white: 0.10)))
                    .overlay(Circle().strokeBorder(hot ? Color.white : Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .white.opacity(hot ? 0.25 : 0), radius: 12)
                    .background(Circle().fill(Color.white.opacity(hot ? 0.08 : 0)).padding(-6))
                Text(d.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: 80)
            }
            .foregroundStyle(.white.opacity(d.online ? 0.92 : 0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.item == nil || model.busy)
        .onHover { inside in if inside { model.aimed = d.id } else if model.aimed == d.id { model.aimed = nil } }
        .help(d.online ? "Drop on \(d.name)" : "\(d.name) is away — Jarvis holds it until it's back")
    }

    // MARK: the item

    private var itemCard: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                if let thumb = model.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: model.item?.symbol ?? "square.and.arrow.down")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(height: 92).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item?.caption ?? "Nothing in front").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                Text(model.item?.detail ?? "Paste or drop a file").font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 124, height: 152)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.085)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(model.item == nil ? 0.12 : 0.2),
                          style: StrokeStyle(lineWidth: 1, dash: model.item == nil ? [4, 4] : [])))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        .offset(drag)
        .position(centre)
        .gesture(fling)
        .help(model.item == nil ? "Paste (⌘V) or drop a file here" : "Fling toward a device")
    }

    private var fling: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard model.item != nil, !model.busy else { return }
                drag = v.translation
                let vector = CGVector(dx: v.translation.width, dy: v.translation.height)
                if let d = HoloOrbitLayout.target(for: vector, devices: model.targets, minLength: 24) { model.aimed = d.id }
            }
            .onEnded { v in
                let throwVector = CGVector(dx: v.predictedEndTranslation.width, dy: v.predictedEndTranslation.height)
                let target = model.item == nil ? nil : HoloOrbitLayout.target(for: throwVector, devices: model.targets)
                if let target {
                    withAnimation(.easeIn(duration: 0.22)) {
                        let len = max(1, hypot(throwVector.dx, throwVector.dy))
                        drag = CGSize(width: throwVector.dx / len * ringRadius, height: throwVector.dy / len * ringRadius)
                    }
                    model.choose(target)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(320))
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = .zero }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero }
                }
            }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 12) {
            Spacer()
            status
            chips
        }
        .padding(.horizontal, 10).padding(.bottom, 18)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .choosing:
            Text(model.item == nil ? "Paste or drop a file" : "Fling toward a device · or click one")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        case .sending(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Sending to \(name)…")
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        case .waiting(let line), .landed(let line):
            Label(line, systemImage: model.phase == .landed(line) ? "checkmark.circle.fill" : "paperplane")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
        case .failed(let why):
            HStack(spacing: 8) {
                Label(why, systemImage: "exclamationmark.triangle").lineLimit(2)
                if model.onRetry != nil {
                    Button("Try again") { model.onRetry?() }.buttonStyle(.plain).underline()
                }
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
        case .off:
            Text("Holo Drop is off — turn it on in Integrations").font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        case .unavailable(let why):
            Text(why).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(HoloAction.allCases) { a in
                let on = model.action == a
                Button { model.override = a } label: {
                    Text(a.title).font(.system(size: 10.5, weight: on ? .semibold : .regular)).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .foregroundStyle(on ? JcAccent.onFill : Color.white.opacity(0.72))
                        .background(Capsule().fill(on ? JcAccent.fill : Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
    }
}

/// Turns what was dropped, pasted or shared into a `HoloItem`.
enum HoloItemLoader {
    /// Every file becomes a file; otherwise the first web address, else the first text.
    /// `copyFiles`: copy shared files into this process's temporary folder first (the Share
    /// extension's access to them ends with the request).
    static func load(_ providers: [NSItemProvider], copyFiles: Bool = false) async -> HoloItem? {
        var files: [URL] = []
        var link: HoloItem?
        var text: String?
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let u = await url(p, UTType.fileURL.identifier), u.isFileURL {
                files.append(copyFiles ? (copyToTemp(u) ?? u) : u)
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let u = await url(p, UTType.url.identifier) {
                if u.isFileURL { files.append(copyFiles ? (copyToTemp(u) ?? u) : u) } else if link == nil { link = .link(u, title: nil) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
                      let u = await fileCopy(p, UTType.movie.identifier) {
                files.append(u)
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let u = await imageFile(p) {
                files.append(u)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), text == nil {
                text = await string(p)
            } else if p.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                      let u = await fileCopy(p, UTType.data.identifier) {
                files.append(u)
            }
        }
        if !files.isEmpty { return .files(files) }
        if let link { return link }
        return text.flatMap(HoloItem.fromText)
    }

    /// What's on the clipboard (⌘V in the popup).
    @MainActor
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> HoloItem? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let image = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff]) != nil,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let u = tempFolder().appendingPathComponent("Pasted image.png")
            if (try? png.write(to: u)) != nil { return .files([u]) }
        }
        if let s = pb.string(forType: .string) { return HoloItem.fromText(s) }
        return nil
    }

    static func tempFolder() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop-" + UUID().uuidString,
                                                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func copyToTemp(_ u: URL) -> URL? {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        let dest = tempFolder().appendingPathComponent(u.lastPathComponent)
        return (try? FileManager.default.copyItem(at: u, to: dest)) != nil ? dest : nil
    }

    private static func url(_ p: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let u = item as? URL { cont.resume(returning: u); return }
                if let d = item as? Data { cont.resume(returning: URL(dataRepresentation: d, relativeTo: nil)); return }
                if let s = item as? String { cont.resume(returning: URL(string: s)); return }
                cont.resume(returning: nil)
            }
        }
    }

    private static func string(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let s = item as? String { cont.resume(returning: s); return }
                if let d = item as? Data { cont.resume(returning: String(data: d, encoding: .utf8)); return }
                if let a = item as? NSAttributedString { cont.resume(returning: a.string); return }
                cont.resume(returning: nil)
            }
        }
    }

    /// The provider's file, copied before its temporary copy goes away.
    private static func fileCopy(_ p: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { u, _ in
                guard let u else { cont.resume(returning: nil); return }
                let dest = tempFolder().appendingPathComponent(p.suggestedName.map { name in
                    name + (u.pathExtension.isEmpty || (name as NSString).pathExtension == u.pathExtension
                            ? "" : "." + u.pathExtension)
                } ?? u.lastPathComponent)
                cont.resume(returning: (try? FileManager.default.copyItem(at: u, to: dest)) != nil ? dest : nil)
            }
        }
    }

    private static func imageFile(_ p: NSItemProvider) async -> URL? {
        if let u = await fileCopy(p, UTType.image.identifier) { return u }
        let data: Data? = await withCheckedContinuation { cont in
            _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in cont.resume(returning: d) }
        }
        guard let data, let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let u = tempFolder().appendingPathComponent((p.suggestedName ?? "Image") + ".png")
        return (try? png.write(to: u)) != nil ? u : nil
    }
}

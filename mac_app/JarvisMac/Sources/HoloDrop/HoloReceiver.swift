import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What arriving does for a drop and its action (pure; tested).
struct HoloArrivalPlan: Equatable {
    /// The bytes come from the server (or arrived over the LAN).
    var fetch = false
    /// Saved to ~/Downloads/Holo Drop: the file itself, a .webloc for a link, a .txt for text.
    var save = false
    /// Opened right away (a web link in the browser, a file in its app).
    var open = false
    /// Open was asked but isn't done unprompted (an app, a script, an odd link): the card's
    /// Open button does it.
    var openHeld = false
    var copy = false
    /// Text asked to "open" is shown on the card.
    var show = false

    static func make(_ drop: HoloDropRecord, action: HoloAction, executable: Bool = false) -> HoloArrivalPlan {
        var p = HoloArrivalPlan()
        p.save = action.saves
        p.copy = action.copies
        switch drop.kind {
        case .link, .text:
            if action.opens {
                if drop.webURL != nil { p.open = true } else if drop.kind == .link { p.openHeld = true } else { p.show = true }
            }
        case .image, .video, .file:
            p.fetch = true
            if action.opens { if executable { p.openHeld = true } else { p.open = true } }
        }
        return p
    }

    /// Files of these kinds never open by themselves. Judged on the name as it's written to disk
    /// (`HoloFiles.safeName`: control and format characters gone, spaces trimmed), so
    /// "run.terminal\u{7}" or "x.terminal " can't slip past as an unknown extension.
    static func isExecutable(name: String, mime: String) -> Bool {
        let ext = (HoloFiles.safeName(name) as NSString).pathExtension.lowercased()
        if ["app", "command", "tool", "sh", "zsh", "bash", "pkg", "mpkg", "dmg", "scpt", "applescript",
            "workflow", "terminal", "jar", "py", "rb", "pl", "action", "prefpane", "kext", "webloc",
            "fileloc", "inetloc", "shortcut"].contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) {
            return t.conforms(to: .executable) || t.conforms(to: .applicationBundle) || t.conforms(to: .script)
        }
        return mime == "application/x-executable" || mime == "application/x-mach-binary"
    }

    /// The written file itself: its final name, the type macOS sees, or an executable bit.
    static func unsafeToOpen(_ file: URL) -> Bool {
        if isExecutable(name: file.lastPathComponent, mime: "") { return true }
        if let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .executable) || type.conforms(to: .applicationBundle) || type.conforms(to: .script) {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: file.path)
    }
}

/// Lands drops on this Mac: fetches the bytes, saves / opens / copies as asked, and shows the
/// floating card where it was aimed.
@MainActor
final class HoloReceiver {
    static let shared = HoloReceiver()

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo Drop", isDirectory: true)
    }

    static var inbox: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop-inbox", isDirectory: true)
    }

    /// Lands one drop. `file`: its bytes already here (the LAN path); else fetched with `api`.
    /// Returns the outcome for `/landed` (or the LAN reply).
    func land(_ drop: HoloDropRecord, fromName: String, file: URL? = nil, api: HoloDropAPI?) async -> (HoloOutcome, String?) {
        let action = drop.action ?? .open
        let executable = HoloArrivalPlan.isExecutable(name: drop.name, mime: drop.mime)
        var plan = HoloArrivalPlan.make(drop, action: action, executable: executable)
        let card = HoloCardModel(drop: drop, fromName: fromName)
        HoloCards.shared.show(card)

        var local: URL?
        if plan.fetch {
            card.state = .receiving
            do {
                let tmp: URL
                if let file { tmp = file } else if let api { tmp = try await api.content(drop.id) } else {
                    throw HoloFailure.notReachable
                }
                let written = try Self.intoInbox(tmp, drop: drop)
                local = written
                card.file = written
                card.loadThumbnail()
                // Decide on what's actually on disk now, not the name the sender gave.
                if plan.open, HoloArrivalPlan.unsafeToOpen(written) {
                    plan.open = false
                    plan.openHeld = true
                }
            } catch {
                let why = (error as? HoloFailure)?.message ?? error.localizedDescription
                card.state = .failed(why)
                return (.failed, why)
            }
        }
        card.state = .ready
        var saved = false, opened = false, copied = false
        if plan.save, let u = save(drop, local: local) {
            saved = true
            card.savedFile = u
            if local != nil { local = u; card.file = u }
        }
        if plan.open {
            opened = open(drop, local: local)
        }
        if plan.openHeld { card.note = "Click Open to open it" }
        if plan.copy {
            copied = copy(drop, local: local)
            card.copied = copied
        }
        if plan.show { card.expanded = true }
        let outcome = HoloOutcome(saved: saved, opened: opened, copied: copied, shown: true)
        card.outcome = outcome
        return (outcome, nil)
    }

    // MARK: the steps

    /// The fetched bytes under a safe name in this drop's own folder (two drops of the same
    /// file never collide), quarantined so Gatekeeper checks anything run from it.
    static func intoInbox(_ tmp: URL, drop: HoloDropRecord) throws -> URL {
        let folder = inbox.appendingPathComponent(drop.id.isEmpty ? UUID().uuidString : HoloFiles.safeName(drop.id),
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(HoloFiles.safeName(drop.name, fallback: "Holo Drop"))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        // The LAN receiver's own folder for this upload is empty now.
        let parent = tmp.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("HoloDrop-lan-") { try? FileManager.default.removeItem(at: parent) }
        quarantine(dest)
        return dest
    }

    static func quarantine(_ u: URL) {
        var url = u
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Jarvis",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? url.setResourceValues(values)
    }

    /// Into ~/Downloads/Holo Drop, never over an existing file.
    func save(_ drop: HoloDropRecord, local: URL?) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
            func dest(_ name: String) -> URL {
                Self.downloads.appendingPathComponent(HoloFiles.unique(HoloFiles.safeName(name)) {
                    fm.fileExists(atPath: Self.downloads.appendingPathComponent($0).path)
                })
            }
            switch drop.kind {
            case .image, .video, .file:
                guard let local else { return nil }
                let to = dest(drop.name.isEmpty ? local.lastPathComponent : drop.name)
                try fm.moveItem(at: local, to: to)
                return to
            case .link:
                let target = drop.url.isEmpty ? drop.text : drop.url
                guard !target.isEmpty else { return nil }
                let to = dest(HoloFiles.safeName(drop.displayName, fallback: "Link") + ".webloc")
                let data = try PropertyListSerialization.data(fromPropertyList: ["URL": target], format: .xml, options: 0)
                try data.write(to: to)
                return to
            case .text:
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                let to = dest("Holo Drop text \(stamp).txt")
                try drop.text.write(to: to, atomically: true, encoding: .utf8)
                return to
            }
        } catch {
            NSLog("Jarvis: Holo Drop save failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func open(_ drop: HoloDropRecord, local: URL?) -> Bool {
        if let local { return NSWorkspace.shared.open(local) }
        if let u = drop.webURL { return NSWorkspace.shared.open(u) }
        if drop.kind == .link, let u = URL(string: drop.url), u.scheme != nil {
            return NSWorkspace.shared.open(u)   // only from the card's Open (never unprompted)
        }
        return false
    }

    @discardableResult
    func copy(_ drop: HoloDropRecord, local: URL?) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch drop.kind {
        case .link:
            let s = drop.url.isEmpty ? drop.text : drop.url
            if let u = URL(string: s) { pb.writeObjects([u as NSURL]) }
            return pb.setString(s, forType: .string)
        case .text:
            return pb.setString(drop.text, forType: .string)
        case .image, .video, .file:
            guard let local else { return false }
            var objects: [NSPasteboardWriting] = [local as NSURL]
            if drop.kind == .image, let image = NSImage(contentsOf: local) { objects.append(image) }
            return pb.writeObjects(objects)
        }
    }
}

// MARK: - the floating card

@MainActor
@Observable
final class HoloCardModel: Identifiable {
    enum State: Equatable { case receiving, ready, failed(String) }

    let id = UUID()
    let drop: HoloDropRecord
    let fromName: String
    let arrived = Date()
    var state: State = .ready
    var file: URL?
    var savedFile: URL?
    var copied = false
    var expanded = false
    var note: String?
    var outcome: HoloOutcome?
    var thumbnail: NSImage?
    var hovering = false

    init(drop: HoloDropRecord, fromName: String) {
        self.drop = drop
        self.fromName = fromName
    }

    /// "From iPhone · just now".
    var fromLine: String {
        let at = drop.created ?? arrived
        let secs = max(0, Date().timeIntervalSince(at))
        let when = secs < 60 ? "just now" : secs < 3_600 ? "\(Int(secs / 60)) min ago" : "earlier"
        return "From \(fromName) · \(when)"
    }

    var symbol: String {
        switch drop.kind {
        case .link: return "link"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .video: return "film"
        case .file: return "doc"
        }
    }

    func loadThumbnail() {
        guard let file else { return }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 232, height: 116), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.thumbnail = image } }
        }
    }

    // The card's buttons.

    func open() {
        _ = HoloReceiver.shared.open(drop, local: savedFile ?? file)
        HoloCards.shared.dismiss(self, after: 0.6)
    }

    func save() {
        if let savedFile {
            NSWorkspace.shared.activateFileViewerSelecting([savedFile])
            return
        }
        if let u = HoloReceiver.shared.save(drop, local: file) {
            savedFile = u
            if file != nil { file = u }
        }
    }

    func copy() {
        copied = HoloReceiver.shared.copy(drop, local: savedFile ?? file)
    }
}

/// The cards on screen: each lands where it was aimed (on the main display), a little lower
/// when another card already sits there; folds itself a while after landing unless the pointer
/// is on it.
@MainActor
final class HoloCards {
    static let shared = HoloCards()
    private var panels: [UUID: NSPanel] = [:]
    static let stayFor: TimeInterval = 14

    static var mainScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    }

    func show(_ card: HoloCardModel) {
        guard let screen = Self.mainScreen else { return }
        var frame = HoloGeometry.cardFrame(position: card.drop.position, visible: screen.visibleFrame)
        while panels.values.contains(where: { abs($0.frame.minX - frame.minX) < 24 && abs($0.frame.minY - frame.minY) < 24 }),
              frame.minY - 30 > screen.visibleFrame.minY {
            frame.origin.y -= 30
            frame.origin.x += 12
        }
        let panel = HoloPanel.make(frame: frame)
        let host = HoloSwipeHostingView(rootView: HoloCardView(card: card))
        host.onSwipe = { [weak self, weak card] dx in
            guard let self, let card else { return }
            self.dismiss(card, slide: dx)
        }
        panel.contentView = host
        panels[card.id] = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }
        Sounds.play(.decided)
        foldLater(card)
    }

    private func foldLater(_ card: HoloCardModel) {
        Task { @MainActor [weak self, weak card] in
            while true {
                try? await Task.sleep(for: .seconds(Self.stayFor))
                guard let self, let card, self.panels[card.id] != nil else { return }
                if card.hovering || card.state == .receiving || card.expanded { continue }
                self.dismiss(card)
                return
            }
        }
    }

    func dismiss(_ card: HoloCardModel, slide: CGFloat = 0, after delay: TimeInterval = 0) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, let panel = self.panels.removeValue(forKey: card.id) else { return }
            var to = panel.frame
            to.origin.x += slide == 0 ? 0 : (slide > 0 ? 260 : -260)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
                if slide != 0 { panel.animator().setFrame(to, display: true) }
            }, completionHandler: { panel.orderOut(nil) })
        }
    }

    /// A short line near the top right ("Landed on iPhone · Saved") for a drop this Mac sent
    /// after its popup closed.
    func toast(_ line: String, symbol: String = "checkmark.circle.fill") {
        guard let screen = Self.mainScreen else { return }
        let size = CGSize(width: 300, height: 44)
        let v = screen.visibleFrame
        let panel = HoloPanel.make(frame: CGRect(x: v.maxX - size.width - 16, y: v.maxY - size.height - 12,
                                                 width: size.width, height: size.height))
        panel.contentView = NSHostingView(rootView: HoloToastView(line: line, symbol: symbol))
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}

/// A floating panel on every Space that never takes focus from the app you're in.
enum HoloPanel {
    static func make(frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        return p
    }
}

/// The card's view, hosted so a two-finger sideways swipe throws it away.
final class HoloSwipeHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: ((CGFloat) -> Void)?
    private var dx: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        if event.phase == .began { dx = 0 }
        dx += event.scrollingDeltaX
        if abs(dx) > 90 {
            let d = dx
            dx = 0
            onSwipe?(d)
        }
        if event.phase == .ended || event.phase == .cancelled { dx = 0 }
    }
}

struct HoloCardView: View {
    @Bindable var card: HoloCardModel

    var body: some View {
        VStack(spacing: 0) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(card.drop.displayName).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(card.expanded ? 1 : 2)
                Text(statusLine).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 9)
            buttons.padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: HoloGeometry.cardSize.width, height: HoloGeometry.cardSize.height)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.08).opacity(0.94)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if card.hovering {
                Button { HoloCards.shared.dismiss(card) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain).foregroundStyle(.white).padding(7).help("Dismiss (or swipe it away)")
            }
        }
        .onHover { card.hovering = $0 }
        .environment(\.colorScheme, .dark)
    }

    private var statusLine: String {
        switch card.state {
        case .receiving: return "Receiving from \(card.fromName)…"
        case .failed(let why): return "Didn't arrive — \(why)"
        case .ready:
            if let note = card.note { return note }
            if let outcome = card.outcome, outcome != .shown, outcome != .failed {
                return "\(outcome.label) · from \(card.fromName)"
            }
            return card.fromLine
        }
    }

    @ViewBuilder private var thumb: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if card.drop.kind == .text {
                ScrollView {
                    Text(card.drop.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
                }
            } else if let image = card.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else if card.state == .receiving {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: card.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    if card.drop.kind == .link, let host = card.drop.webURL?.host {
                        Text(host).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(height: 112).clipped()
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Open") { card.open() }.buttonStyle(HoloCardButton(main: true))
                .disabled(card.state != .ready)
            Button(card.savedFile == nil ? "Save" : "Saved") { card.save() }.buttonStyle(HoloCardButton(main: false))
                .disabled(card.state != .ready)
                .help(card.savedFile == nil ? "Save to Downloads › Holo Drop" : "Show in Finder")
            Button(card.copied ? "Copied" : "Copy") { card.copy() }.buttonStyle(HoloCardButton(main: false))
                .disabled(card.state != .ready)
        }
    }
}

/// Open is the one filled (white) button; Save and Copy are grey capsules.
struct HoloCardButton: ButtonStyle {
    let main: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: main ? .semibold : .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .foregroundStyle(main ? JcAccent.onFill : Color.white.opacity(0.82))
            .background(Capsule().fill(main ? JcAccent.fill : Color.white.opacity(0.10)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct HoloToastView: View {
    let line: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            Text(line).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(white: 0.07).opacity(0.95)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }
}

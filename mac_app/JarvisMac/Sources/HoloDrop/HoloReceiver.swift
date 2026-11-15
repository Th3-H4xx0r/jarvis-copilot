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
    /// The card's three buttons.
    enum Action: Equatable { case open, save, copy }

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
    /// A button is working: it spins, the other two grey out and wait.
    var busy: Action?
    /// Quick Look is still making the preview (the card keeps its spinner until it's here).
    var previewing = false
    /// Tests stand in for the buttons' work here; nil: the real Open / Save / Copy.
    @ObservationIgnored var perform: ((Action) -> Void)?

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

    /// The picture the card is made of (a photo, a video's frame, a document's page), as
    /// width ÷ height. Nil: a compact card (a link, text, or a file with no preview).
    var heroAspect: CGFloat? {
        guard drop.kind != .link, drop.kind != .text, let size = thumbnail?.size,
              size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// Finder's icon for a fetched file that has no picture to show.
    var fileIcon: NSImage? {
        guard drop.kind != .link, drop.kind != .text, let f = savedFile ?? file else { return nil }
        return NSWorkspace.shared.icon(forFile: f.path)
    }

    /// A preview big enough to fill the largest card at 2x. Saving can move the file while
    /// Quick Look is still reading it; then it tries again at the new place.
    func loadThumbnail() {
        guard let file else { return }
        previewing = true
        let box = max(HoloGeometry.heroMax.width, HoloGeometry.heroMax.height)
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: box, height: box), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let image {
                        self.thumbnail = image
                    } else if let now = self.file, now != file {
                        self.loadThumbnail()
                        return
                    }
                    self.previewing = false
                }
            }
        }
    }

    // The card's buttons.

    /// A button pressed: it spins and the others grey out until it's done. The work starts a
    /// frame later (so the spinner is drawn first) and the spinner holds for a moment, so a
    /// quick action reads as an answered click rather than a flicker.
    func run(_ action: Action) {
        guard busy == nil, state == .ready else { return }
        busy = action
        Task { @MainActor in
            let began = Date()
            try? await Task.sleep(for: .milliseconds(30))
            if let perform {
                perform(action)
            } else {
                switch action {
                case .open: open()
                case .save: save()
                case .copy: copy()
                }
            }
            let left = 0.35 - Date().timeIntervalSince(began)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            busy = nil
        }
    }

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
        var frame = HoloGeometry.cardFrame(position: card.drop.position, visible: screen.visibleFrame,
                                           size: HoloCardView.size(for: card))
        while panels.values.contains(where: { abs($0.frame.minX - frame.minX) < 24 && abs($0.frame.minY - frame.minY) < 24 }),
              frame.minY - 30 > screen.visibleFrame.minY {
            frame.origin.y -= 30
            frame.origin.x += 12
        }
        let panel = HoloPanel.make(frame: frame)
        let host = HoloSwipeHostingView(rootView: HoloCardView(card: card))
        // The panel's size is set here (refit below), not by the view: it fills whatever the
        // panel is, so a growing card animates as one piece.
        host.sizingOptions = []
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
        followSize(card)
    }

    /// Refits the panel whenever what the card's size depends on changes: the picture
    /// arriving (a compact "Receiving…" card grows into the photo), failing, or text opening.
    private func followSize(_ card: HoloCardModel) {
        withObservationTracking {
            _ = (card.thumbnail, card.state, card.expanded, card.file)
        } onChange: { [weak self, weak card] in
            Task { @MainActor in
                guard let self, let card, self.panels[card.id] != nil else { return }
                self.refit(card)
                self.followSize(card)
            }
        }
    }

    private func refit(_ card: HoloCardModel) {
        guard let panel = panels[card.id] else { return }
        let size = HoloCardView.size(for: card)
        guard panel.frame.size != size,
              let visible = (panel.screen ?? Self.mainScreen)?.visibleFrame else { return }
        let to = HoloGeometry.refit(panel.frame, to: size, visible: visible)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(to, display: true)
        }, completionHandler: { panel.invalidateShadow() })
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

/// The arrival card. A picture (photo, video frame, document page) IS the card: edge to edge
/// at its own aspect ratio, with the name, a quiet status and three icon buttons over a soft
/// shade along its bottom. Links, text and files without a preview get a compact card: an
/// icon, the name and status, and the same buttons. Black and white only; the one filled
/// (white) button is Open.
struct HoloCardView: View {
    @Bindable var card: HoloCardModel

    static let corner: CGFloat = 14

    /// The card's size: a picture's from its aspect ratio, a compact card's from its content.
    @MainActor
    static func size(for card: HoloCardModel) -> CGSize {
        if let aspect = card.heroAspect { return HoloGeometry.heroSize(aspect: aspect) }
        let width = HoloGeometry.compactWidth
        let probe = NSHostingView(rootView: HoloCardView(card: card)
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        return CGSize(width: width, height: ceil(max(probe.fittingSize.height, 52)))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .overlay(alignment: closeCorner) { closeButton }
            .animation(.easeOut(duration: 0.15), value: card.hovering)
            .onHover { card.hovering = $0 }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Holo Drop from \(card.fromName): \(card.drop.displayName), \(statusLine)")
    }

    @ViewBuilder private var content: some View {
        if let image = card.thumbnail, card.heroAspect != nil {
            hero(image)
        } else if card.drop.kind == .text {
            textCard
        } else {
            compact
        }
    }

    // MARK: the picture card

    private func hero(_ image: NSImage) -> some View {
        Color.black
            .overlay { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
            .clipped()
            .overlay { if card.drop.kind == .video { playGlyph } }
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    titleAndStatus(titleSize: 12, lines: 1)
                    if !failed { icons }
                }
                .padding(.horizontal, 12).padding(.top, 30).padding(.bottom, 11)
                // The only gradient: enough shade for white text and icons on any photo.
                .background(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                                   .init(color: .black.opacity(0.32), location: 0.45),
                                                   .init(color: .black.opacity(0.62), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: 1)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .accessibilityHidden(true)
    }

    // MARK: the compact card (link, file with no preview, arriving, failed)

    private var compact: some View {
        HStack(spacing: 11) {
            tile
            titleAndStatus(titleSize: 12.5, lines: card.drop.kind == .link ? 2 : 1)
            if !failed { icons }
        }
        .padding(12)
    }

    @ViewBuilder private var tile: some View {
        if card.state == .receiving || (card.previewing && !failed) {
            JcLoader(size: 16).foregroundStyle(.white.opacity(0.8)).frame(width: 38, height: 38).background(tileShape)
        } else if !failed, let icon = card.fileIcon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 38, height: 38)
        } else {
            Image(systemName: failed ? "exclamationmark.triangle" : card.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 38, height: 38)
                .background(tileShape)
        }
    }

    private var tileShape: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08))
    }

    // MARK: the text card

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            textBody
            HStack(spacing: 10) {
                Text(statusLine).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !failed { icons }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var textBody: some View {
        let text = Text(card.drop.text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
        if card.expanded {
            ScrollView {
                text.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        } else {
            text.lineLimit(4).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    // MARK: pieces

    private func titleAndStatus(titleSize: CGFloat, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.drop.displayName)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(lines)
                .truncationMode(lines == 1 ? .middle : .tail)
            Text(statusLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failed: Bool {
        if case .failed = card.state { return true }
        return false
    }

    /// The close button sits in a corner the icons don't use: over the icon's corner on a
    /// compact card (like a notification), top right on a picture or text.
    private var closeCorner: Alignment {
        card.heroAspect == nil && card.drop.kind != .text ? .topLeading : .topTrailing
    }

    @ViewBuilder private var closeButton: some View {
        if card.hovering {
            Button { HoloCards.shared.dismiss(card) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(closeCorner == .topLeading ? 4 : 8)
            .help("Dismiss (or swipe it away)")
            .accessibilityLabel("Dismiss")
            .transition(.opacity)
        }
    }

    private var statusLine: String {
        switch card.state {
        case .receiving: return "Receiving from \(card.fromName)…"
        case .failed(let why): return "Didn't arrive — \(why)"
        case .ready:
            let line: String
            if let note = card.note {
                line = note
            } else if let outcome = card.outcome, outcome != .shown, outcome != .failed {
                line = "\(outcome.label) · from \(card.fromName)"
            } else {
                line = card.fromLine
            }
            // A titled link: its site is worth more than anything else on the line.
            if card.drop.kind == .link, !card.drop.title.isEmpty, var host = card.drop.webURL?.host {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                return "\(host) · \(line)"
            }
            return line
        }
    }

    private var icons: some View {
        HStack(spacing: 6) {
            iconButton(.open, symbol: "arrow.up.forward.app", label: "Open", help: "Open", main: true)
            if card.savedFile == nil {
                iconButton(.save, symbol: "square.and.arrow.down", label: "Save", help: "Save to Downloads › Holo Drop")
            } else {
                iconButton(.save, symbol: "folder", label: "Show in Finder", help: "Saved — show in Finder")
            }
            if card.copied {
                iconButton(.copy, symbol: "checkmark", label: "Copied", help: "Copied — click to copy again")
            } else {
                iconButton(.copy, symbol: "doc.on.doc", label: "Copy", help: "Copy")
            }
        }
        .animation(.easeOut(duration: 0.15), value: card.busy)
    }

    /// One icon button. Working: its glyph becomes the Jarvis loader. Another one working, or
    /// the drop still arriving: greyed out and off.
    private func iconButton(_ action: HoloCardModel.Action, symbol: String, label: String, help: String,
                            main: Bool = false) -> some View {
        let working = card.busy == action
        let off = card.busy != nil || card.state != .ready
        return Button { card.run(action) } label: {
            ZStack {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).opacity(working ? 0 : 1)
                if working { JcLoader(size: 13) }
            }
        }
        .buttonStyle(HoloIconButton(main: main))
        .disabled(off)
        .opacity(off && !working ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A round icon button: grey, or white-filled for the card's one main action (Open).
struct HoloIconButton: ButtonStyle {
    let main: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoloIconButtonBody(configuration: configuration, main: main)
    }
}

private struct HoloIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let main: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(main ? JcAccent.onFill : Color.white.opacity(0.92))
            .frame(width: 26, height: 26)
            .background(Circle().fill(main ? JcAccent.fill.opacity(hover && enabled ? 0.88 : 1)
                                           : Color.white.opacity(hover && enabled ? 0.24 : 0.16)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
            .onHover { hover = $0 }
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

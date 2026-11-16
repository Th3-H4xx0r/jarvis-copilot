import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - The screen

/// Remote Desktop, full screen: the warning / approving / error cards in the app's look, then the
/// PC's desktop with the trackpad, keyboard bar, clipboard, files and Disconnect.
struct RdpSessionScreen: View {
    @Bindable var model: RdpSessionModel
    let close: () -> Void

    @State private var modifiers = RdpModifiers()
    @State private var keyboardUp = false
    @State private var showFiles = false
    @State private var waking = false

    var body: some View {
        ZStack {
            JcTheme.bg.ignoresSafeArea()
            switch model.state {
            case .connected:
                desktop
            case .connecting where model.client?.image != nil:
                desktop
            default:
                statusCard.padding(.horizontal, JcUnified.pageInset)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.state == .connected)
        .onChange(of: model.state) { _, state in
            if case .ended = state { close() }
            if state == .connected { try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers) }
        }
        .sheet(isPresented: $showFiles) { RdpFilesSheet(deviceId: model.deviceId, pcName: model.pcName) }
    }

    // MARK: status

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 0) {
            JcCard {
                HStack(spacing: 12) {
                    JcIconSquare(symbol: "display")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Desktop").font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                        Text(model.pcName).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                    Spacer()
                }
                statusBody.padding(.top, 16)
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var statusBody: some View {
        switch model.state {
        case .idle, .checking:
            progress("Checking \(model.pcName)…")
            cancelButton
        case .approving:
            progress("Approve with Face ID to connect")
            Text("Jarvis asks \(model.pcName) for your Windows password; it's sent encrypted to this iPhone only.")
                .font(.footnote).foregroundStyle(JcTheme.muted).padding(.top, 8)
            cancelButton
        case .connecting:
            progress("Connecting to \(model.pcName)…")
            cancelButton
        case .warn(let w):
            let copy = RdpCopy.warning(w, pc: model.pcName)
            Label { Text(copy.title) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.amber)
            Text(copy.detail).font(.subheadline).foregroundStyle(JcTheme.muted).padding(.top, 6)
            HStack(spacing: 10) {
                Button("Cancel") { model.cancel(); close() }.buttonStyle(MacActionButtonStyle())
                Button("Connect anyway") { model.start(confirm: true) }.buttonStyle(MacActionButtonStyle(prominent: true))
            }
            .padding(.top, 16)
        case .error(let f):
            Text(RdpCopy.failure(f, pc: model.pcName))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(JcTheme.text)
            HStack(spacing: 10) {
                Button("Close") { model.cancel(); close() }.buttonStyle(MacActionButtonStyle())
                if f.offersWake {
                    Button {
                        waking = true
                        Task { _ = await model.wake(); waking = false; model.start() }
                    } label: {
                        if waking { JcLoader(size: 16) } else { Label("Wake PC", systemImage: "power") }
                    }
                    .buttonStyle(MacActionButtonStyle(prominent: true))
                } else if f == .connectionLost {
                    Button("Reconnect") { model.reconnect() }.buttonStyle(MacActionButtonStyle(prominent: true))
                } else if f != .notInThisBuild {
                    Button("Try again") { model.start() }.buttonStyle(MacActionButtonStyle(prominent: true))
                }
            }
            .padding(.top, 16)
        case .connected, .ended:
            EmptyView()
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            JcLoader(size: 18)
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { model.cancel(); close() }
            .buttonStyle(MacActionButtonStyle())
            .padding(.top, 16)
    }

    // MARK: desktop

    private var desktop: some View {
        VStack(spacing: 0) {
            topBar
            RdpDesktopView(client: model.client, modifiers: $modifiers, keyboardUp: $keyboardUp)
                .ignoresSafeArea(.container, edges: .horizontal)
            RdpKeyboardBar(client: model.client, modifiers: $modifiers, keyboardUp: $keyboardUp) {
                if let text = UIPasteboard.general.string {
                    model.client?.setClipboard(text)
                    // Give the PC a moment to take the format list, then paste.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        for (code, down) in RdpModifiers.chord([.ctrl, .v]) { model.client?.key(code, down: down) }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let note = model.note {
                Text(note)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(JcTheme.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(JcTheme.surfaceAlt, in: Capsule())
                    .padding(.top, 56)
                    .task(id: note) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        model.note = nil
                    }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle().fill(JcAccent.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.pcName).font(.system(size: 14, weight: .semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
                Text(quality).font(.system(size: 11)).foregroundStyle(JcTheme.muted).monospacedDigit()
            }
            Spacer(minLength: 8)
            barButton("folder", "Files") { showFiles = true }
            Button { model.disconnect() } label: {
                Text("Disconnect").font(.system(size: 14, weight: .semibold)).foregroundStyle(JcButton.label)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(JcButton.fill, in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(JcTheme.bg)
    }

    private var quality: String {
        guard let c = model.client else { return "Connecting" }
        let size = c.desktopSize.width > 0 ? "\(Int(c.desktopSize.width))×\(Int(c.desktopSize.height))" : ""
        return c.fps > 0 ? "Live · \(Int(c.fps.rounded())) fps · \(size)" : "Live · \(size)"
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(JcButton.label)
                .frame(width: 36, height: 32)
                .background(JcButton.fill, in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - The desktop (UIKit: gestures, zoom, the system keyboard)

struct RdpDesktopView: UIViewRepresentable {
    let client: RdpClient?
    @Binding var modifiers: RdpModifiers
    @Binding var keyboardUp: Bool

    func makeUIView(context: Context) -> RdpCanvasView {
        let v = RdpCanvasView()
        v.client = client
        v.onModifiersUsed = { modifiers = RdpModifiers() }
        return v
    }

    func updateUIView(_ v: RdpCanvasView, context: Context) {
        v.client = client
        v.modifiers = modifiers
        v.image = client?.image
        v.setKeyboard(keyboardUp)
    }
}

/// Touch is a trackpad: one finger moves the pointer, tap clicks, two-finger tap right-clicks,
/// two-finger drag scrolls, long press then drag selects/drags, pinch zooms (the view follows the
/// pointer). Typing goes through a hidden key input as Unicode key events.
final class RdpCanvasView: UIView, UIKeyInput {
    var client: RdpClient? {
        didSet { if client !== oldValue { lastSize = .zero } }
    }
    var modifiers = RdpModifiers()
    var onModifiersUsed: (() -> Void)?
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            imageLayer.contents = image
            if let image { desktop = CGSize(width: image.width, height: image.height) }
            setNeedsLayout()
        }
    }

    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private var desktop = CGSize(width: 1280, height: 800)
    private var cursor = CGPoint(x: 640, y: 400)
    private var zoom: CGFloat = 1
    private var zoomCenter: CGPoint?    // desktop point at the view's centre when zoomed
    private var dragging = false
    private var lastSize = CGSize.zero
    private var resizeWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
        let arrow = UIBezierPath()
        arrow.move(to: .zero)
        arrow.addLine(to: CGPoint(x: 0, y: 17))
        arrow.addLine(to: CGPoint(x: 4.5, y: 13))
        arrow.addLine(to: CGPoint(x: 8, y: 20))
        arrow.addLine(to: CGPoint(x: 10.5, y: 19))
        arrow.addLine(to: CGPoint(x: 7, y: 12))
        arrow.addLine(to: CGPoint(x: 12.5, y: 12))
        arrow.close()
        cursorLayer.path = arrow.cgPath
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1
        cursorLayer.actions = ["position": NSNull()]
        layer.addSublayer(cursorLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoTapped))
        twoTap.numberOfTouchesRequired = 2
        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(twoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.35
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        tap.require(toFail: twoTap)
        for g in [pan, tap, twoTap, twoPan, press, pinch] { addGestureRecognizer(g) }
        isAccessibilityElement = true
        accessibilityLabel = "Remote desktop"
        accessibilityHint = "Drag to move the pointer, tap to click, two fingers to scroll"
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: geometry

    /// Where the desktop sits on screen (aspect fit, zoomed around `center`).
    private var desktopRect: CGRect {
        guard desktop.width > 0, desktop.height > 0, bounds.width > 0 else { return bounds }
        let fit = min(bounds.width / desktop.width, bounds.height / desktop.height) * zoom
        let size = CGSize(width: desktop.width * fit, height: desktop.height * fit)
        let c = zoomCenter ?? CGPoint(x: desktop.width / 2, y: desktop.height / 2)
        var origin = CGPoint(x: bounds.midX - c.x * fit, y: bounds.midY - c.y * fit)
        if size.width <= bounds.width { origin.x = (bounds.width - size.width) / 2 } else {
            origin.x = min(0, max(bounds.width - size.width, origin.x))
        }
        if size.height <= bounds.height { origin.y = (bounds.height - size.height) / 2 } else {
            origin.y = min(0, max(bounds.height - size.height, origin.y))
        }
        return CGRect(origin: origin, size: size)
    }

    private var scale: CGFloat { desktopRect.width / max(1, desktop.width) }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = desktopRect
        placeCursor()
        // The session follows the view (rotation): ask the PC for this size × up to 2.
        if bounds.size != lastSize, bounds.width > 100, client != nil {
            lastSize = bounds.size
            resizeWork?.cancel()
            let px = min(UIScreen.main.scale, 2)
            let w = Int(bounds.width * px) & ~1, h = Int(bounds.height * px)
            let work = DispatchWorkItem { [weak self] in self?.client?.resize(width: w, height: h) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func placeCursor() {
        let r = desktopRect
        cursorLayer.position = CGPoint(x: r.minX + cursor.x * scale, y: r.minY + cursor.y * scale)
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 13, height: 21)
        cursorLayer.anchorPoint = .zero
    }

    private func clampCursor() {
        cursor.x = min(max(0, cursor.x), desktop.width - 1)
        cursor.y = min(max(0, cursor.y), desktop.height - 1)
        if zoom > 1 { zoomCenter = cursor }   // the view follows the pointer
    }

    // MARK: gestures

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let speed: CGFloat = 1.6 / max(scale, 0.1)
        cursor.x += d.x * speed
        cursor.y += d.y * speed
        clampCursor()
        client?.move(to: cursor)
        setNeedsLayout()
    }

    @objc private func tapped() { client?.click(1, at: cursor) }
    @objc private func twoTapped() { client?.click(2, at: cursor) }

    @objc private func twoPan(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if abs(d.y) >= abs(d.x), abs(d.y) > 0.5 { client?.wheel(Int(d.y * 3), horizontal: false, at: cursor) }
        else if abs(d.x) > 0.5 { client?.wheel(Int(-d.x * 3), horizontal: true, at: cursor) }
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            client?.button(1, down: true, at: cursor)
        case .changed:
            // Long press then drag: the finger's own movement drives the pointer.
            break
        default:
            if dragging { client?.button(1, down: false, at: cursor) }
            dragging = false
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        zoom = min(4, max(1, zoom * g.scale))
        g.scale = 1
        zoomCenter = zoom > 1 ? cursor : nil
        setNeedsLayout()
    }

    // MARK: keyboard

    private var wantsKeyboard = false

    func setKeyboard(_ up: Bool) {
        guard up != wantsKeyboard else { return }
        wantsKeyboard = up
        if up { becomeFirstResponder() } else { resignFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no

    func insertText(_ text: String) {
        guard let client else { return }
        if !modifiers.latched.isEmpty, text.count == 1, let code = RdpTyping.scancode(for: text) {
            // A latched Ctrl/Alt/Win with a letter is a shortcut, not text.
            var m = modifiers
            for (k, down) in m.events(for: code) { client.key(k, down: down) }
            onModifiersUsed?()
            return
        }
        client.type(text)
    }

    func deleteBackward() { client?.tap(.backspace) }
}

/// Letters and digits as scancodes, for shortcuts typed with a latched modifier (Ctrl+S, Win+E).
enum RdpTyping {
    private static let letters: [Character: Int] = [
        "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
        "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
        "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30, "n": 0x31, "m": 0x32,
        "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06, "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
        " ": 0x39,
    ]

    static func scancode(for text: String) -> RdpKeyCode? {
        guard let ch = text.lowercased().first, let code = letters[ch] else { return nil }
        return RdpKeyCode(scancode: code)
    }
}

// MARK: - Files

/// The transfer folder (shown on the PC as the "Jarvis iPhone" drive) and Send to PC (Holo Drop).
struct RdpFilesSheet: View {
    let deviceId: String
    let pcName: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RdpTransfers.Item] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    Text("This folder shows on \(pcName) as the drive “Jarvis iPhone” while you're connected — drop files in from either side.")
                        .font(.footnote).foregroundStyle(JcTheme.muted).padding(.top, 8)
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photos, maxSelectionCount: 20) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(MacActionButtonStyle())
                        Button { importing = true } label: { Label("Files", systemImage: "doc") }
                            .buttonStyle(MacActionButtonStyle())
                    }
                    .padding(.top, 14)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(JcTheme.muted).padding(.top, 8)
                    }
                    JcSectionLabel("In the folder") { Text(items.isEmpty ? "" : "\(items.count)") }
                    if items.isEmpty {
                        JcCard { Text("Nothing here yet.").font(.subheadline).foregroundStyle(JcTheme.muted) }
                    } else {
                        JcCard(padding: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                JcRow(symbol: "doc", title: item.name,
                                      subtitle: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                                      subtitleLines: 1, last: i == items.count - 1) {
                                    HStack(spacing: 14) {
                                        Button { send(item) } label: { Image(systemName: "paperplane") }
                                            .accessibilityLabel("Send \(item.name) to \(pcName) with Holo Drop")
                                        ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                                    }
                                    .foregroundStyle(JcButton.label)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for u in urls { _ = try? RdpTransfers.copyIn(u) }
                    reload()
                }
            }
            .onChange(of: photos) { _, picked in
                Task {
                    for p in picked {
                        if let data = try? await p.loadTransferable(type: Data.self) {
                            let ext = p.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            _ = try? RdpTransfers.write(data, name: "Photo \(Date().formatted(.dateTime.year().month().day().hour().minute().second())).\(ext)")
                        }
                    }
                    photos = []
                    reload()
                }
            }
            .onAppear(perform: reload)
        }
        .preferredColorScheme(.dark)
    }

    private func reload() { items = RdpTransfers.items() }

    private func send(_ item: RdpTransfers.Item) {
        message = "Sending \(item.name)…"
        Task {
            do {
                try await RdpTransfers.sendToPC(item.url, deviceId: deviceId)
                message = "Sent \(item.name) to \(pcName)"
            } catch {
                message = "Couldn't send: \(apiErrorMessage(error))"
            }
        }
    }
}

// MARK: - Presenting from anywhere

extension View {
    /// Remote Desktop opened from the card, the Tools list or a button.
    func rdpPresenter() -> some View { modifier(RdpPresenterHost()) }
}

private struct RdpPresenterHost: ViewModifier {
    @State private var presenter = RdpPresenter.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { presenter.model != nil },
                                                     set: { if !$0 { presenter.model = nil } })) {
            if let model = presenter.model {
                RdpSessionScreen(model: model) {
                    model.disconnect()
                    presenter.model = nil
                }
            }
        }
    }
}

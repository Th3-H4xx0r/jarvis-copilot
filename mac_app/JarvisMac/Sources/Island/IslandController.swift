import AppKit
import Observation
import SwiftUI

/// What the island views need from the window: its state and the notch size.
@MainActor
@Observable
final class IslandUI {
    var state: IslandStateMachine.State = .hidden
    var geometry = IslandGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: nil,
                                  auxiliaryRightWidth: nil, menuBarHeight: 37)
    var hovering = false
    /// Something the user is typing into (an approval note, a question's Other):
    /// the island stays open while it's set.
    var pinned = false
    /// The expanded island's tab (Agents, Chat, Services, Music, Mail).
    var tab: IslandTab = .agents
    var compactWidth: CGFloat { geometry.width + 2 * IslandController.earWidth }
}

/// The island's window: a borderless, non-activating panel over the notch (or a
/// small bar under the menu bar on screens without one), on every Space and over
/// full-screen apps. The pointer is polled — 60 Hz while open or close by, 20 Hz
/// in a band around the panel, 8 Hz otherwise, nothing while the screen sleeps —
/// and the panel lets clicks through everywhere but the island itself.
/// After coucou's IslandWindowController (github.com/Louis-CFM/coucou, MIT).
@MainActor
final class IslandController {
    static let earWidth: CGFloat = 54
    static let panelSize = CGSize(width: 720, height: 520)

    let ui = IslandUI()
    private let model: AppModel
    private var panel: NSPanel!
    private var machine = IslandStateMachine()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var screenOff = false
    private var screen: NSScreen?

    private static let fast: TimeInterval = 1.0 / 60
    private static let near: TimeInterval = 1.0 / 20
    private static let idle: TimeInterval = 1.0 / 8

    init(model: AppModel) {
        self.model = model
        buildPanel()
        relocate()
        observeSystem()
        start(interval: Self.idle)
    }

    // MARK: public

    func attention() {
        machine.attention(at: now)
        sync()
    }

    func activity() {
        machine.activity(at: now)
        sync()
    }

    func toggle() {
        machine.toggle(at: now)
        sync()
    }

    /// Open on one tab (a shortcut, a dropped file).
    func open(_ tab: IslandTab) {
        ui.tab = tab
        machine.attention(at: now)
        sync()
    }

    func close() {
        machine.close(at: now)
        sync()
    }

    var isExpanded: Bool { machine.state == .expanded }

    // MARK: window

    private func buildPanel() {
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let root = IslandRootView(model: model, ui: ui, controller: self)
            .environment(\.layoutDirection, .leftToRight)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        switch Prefs.display {
        case .notch:
            return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]
        case .menuBar:
            return screens.first ?? NSScreen.main!
        case .followMouse:
            let mouse = NSEvent.mouseLocation
            return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        case .display(let uuid):
            return screens.first { Self.uuid(of: $0) == uuid }
                ?? screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]
        }
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(num.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    func relocate() {
        let s = targetScreen()
        screen = s
        let menuBar = s.frame.maxY - s.visibleFrame.maxY
        ui.geometry = IslandGeometry(screenWidth: s.frame.width, safeAreaTop: s.safeAreaInsets.top,
                                     auxiliaryLeftWidth: s.auxiliaryTopLeftArea?.width,
                                     auxiliaryRightWidth: s.auxiliaryTopRightArea?.width,
                                     menuBarHeight: menuBar > 0 ? menuBar : 24)
        let size = Self.panelSize
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenOff(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenOff(false) }
            }
        }
    }

    private func setScreenOff(_ off: Bool) {
        screenOff = off
        if off { timer?.invalidate(); timer = nil } else { start(interval: Self.idle) }
    }

    // MARK: polling

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func start(interval: TimeInterval) {
        timer?.invalidate()
        timer = nil
        self.interval = interval
        guard !screenOff else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval == Self.idle ? 0.04 : interval == Self.near ? 0.01 : 0.004
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The island's rectangle in panel coordinates (origin bottom-left).
    private func islandRect() -> CGRect {
        let size = Self.panelSize
        let (w, h): (CGFloat, CGFloat)
        switch machine.state {
        case .hidden: (w, h) = (ui.geometry.width, ui.geometry.height)
        case .compact: (w, h) = (ui.compactWidth, ui.geometry.height)
        case .expanded: (w, h) = (IslandRootView.expandedWidth, IslandRootView.expandedHeight(model: model, tab: ui.tab))
        }
        return CGRect(x: (size.width - w) / 2, y: size.height - h, width: w, height: h)
    }

    private func tick() {
        guard let panel else { return }
        if Prefs.display == .followMouse, machine.state != .expanded,
           let s = screen, !s.frame.contains(NSEvent.mouseLocation) {
            relocate()
        }
        let mouse = NSEvent.mouseLocation
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let rect = islandRect()
        let inIsland = rect.insetBy(dx: -6, dy: -6).contains(local)
        let accept = inIsland && machine.state != .hidden || (machine.state == .hidden && inIsland && ui.geometry.hasNotch)
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }
        if inIsland != ui.hovering {
            ui.hovering = inIsland
            if inIsland && Prefs.openOnHover && machine.state != .expanded { machine.attention(at: now) }
            if inIsland && machine.state == .hidden { machine.activity(at: now) }
        }
        let busy = !model.sessions.filter { $0.state != .idle }.isEmpty || !model.pending.isEmpty
        machine.tick(now: now, hovering: inIsland, pinned: ui.pinned || !model.pending.isEmpty,
                     hasSessions: busy || (!Prefs.hideWhenIdle && model.connected))
        sync()
        let nearIsland = rect.offsetBy(dx: pf.minX, dy: pf.minY).insetBy(dx: -200, dy: -160).contains(mouse)
        let inBand = pf.insetBy(dx: -120, dy: -120).contains(mouse)
        let wanted = machine.state == .expanded || nearIsland ? Self.fast : inBand ? Self.near : Self.idle
        if wanted != interval { start(interval: wanted) }
    }

    private func sync() {
        if ui.state != machine.state {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { ui.state = machine.state }
            if machine.state == .expanded {
                panel.makeKey()
            }
        }
    }
}

/// Lets the island sit in the menu bar / notch area and take key focus for text.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

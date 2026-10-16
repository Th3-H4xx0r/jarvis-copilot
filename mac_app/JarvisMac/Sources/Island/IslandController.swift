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
    /// The expanded island's tab (Agents, Chat, Services, Music, Mail, Voice).
    var tab: IslandTab = .agents {
        didSet { if tab != .voice { lastTab = tab } }
    }
    /// The last tab that isn't Voice: what a click on the notch opens.
    private(set) var lastTab: IslandTab = .agents
    /// The Agents tab's limits card (the usage pills open it).
    var showLimits = false
    /// The Agents tab's measured parts (nil until its first layout).
    var agentsTop: CGFloat?
    var agentsList: CGFloat?
    var agentsMeasure: IslandMeasure? {
        guard let agentsTop, let agentsList else { return nil }
        return IslandMeasure(top: agentsTop, list: agentsList)
    }
    var compactWidth: CGFloat { geometry.width + 2 * IslandController.earWidth }
}

/// The island's window: a borderless, non-activating panel over the notch (or a
/// small bar under the menu bar on screens without one), on every Space and over
/// full-screen apps. The pointer is polled — 60 Hz close by, 20 Hz while open
/// or in a band around the panel, once a second otherwise (a mouse-moved
/// monitor wakes it), nothing while the screen sleeps —
/// and the panel lets clicks through everywhere but the island itself.
/// After coucou's IslandWindowController (github.com/Louis-CFM/coucou, MIT).
@MainActor
final class IslandController {
    static let earWidth: CGFloat = 40
    static let panelSize = CGSize(width: 720, height: 560)   // room for the voice panel under the tabs

    let ui = IslandUI()
    private let model: AppModel
    private var panel: NSPanel!
    private var machine = IslandStateMachine()
    private var clickMonitor: Any?
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var screenOff = false
    private var screen: NSScreen?

    private static let fast = IslandTick.fast
    private static let near = IslandTick.near
    private static let idle = IslandTick.idle
    private var moveMonitor: Any?
    private var rightClickMonitor: Any?

    /// The voice panel for the Voice view (JarvisMenu loads it from the dylib).
    var voicePanel: (() -> NSViewController?)?
    /// A right-click on the island: the menu (JarvisMenu), at that point.
    var onMenu: ((NSView, NSPoint) -> Void)?

    init(model: AppModel) {
        self.model = model
        buildPanel()
        relocate()
        observeSystem()
        watchClicksElsewhere()
        watchPointer()
        start(interval: Self.idle)
    }

    /// Far from the island the pointer is polled once a second; a move into the
    /// band around the panel wakes the fast poll at once. Right-clicks on the
    /// island pop the menu.
    private func watchPointer() {
        // A drag too: a file dragged to the notch must find it awake to drop on it.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.interval == Self.idle, let panel = self.panel else { return }
                if panel.frame.insetBy(dx: -120, dy: -120).contains(NSEvent.mouseLocation) { self.tick() }
            }
        }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel, let view = self.panel.contentView,
                      event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                self.onMenu?(view, view.convert(event.locationInWindow, from: nil))
                return nil
            }
        }
    }

    /// Clicks in other apps (and on the see-through parts of the panel, which
    /// pass through) reach only a global monitor; one while the island is open
    /// folds it. Clicks on the island itself are local and never seen here.
    private func watchClicksElsewhere() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.machine.state == .expanded else { return }
                self.machine.clickedOutside(at: self.now)
                self.ui.pinned = false
                self.sync()
            }
        }
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

    /// A click on the notch (not its orb) or the island shortcut: never Voice —
    /// that's the orb's — but the last other tab.
    func toggle() {
        if !isExpanded { ui.tab = IslandTab.forIslandClick(current: ui.tab, last: ui.lastTab) }
        machine.toggle(at: now)
        sync()
    }

    /// Open on one tab (a shortcut, a dropped file). `typing` (the chat
    /// shortcuts) also gives the island the keyboard; nothing else does.
    func open(_ tab: IslandTab, reason: IslandOpenReason = .attention) {
        ui.tab = tab
        machine.attention(at: now)
        sync()
        if IslandFocus.takesKeyboard(reason) { panel.makeKey() }
    }

    func close() {
        machine.close(at: now)
        sync()
    }

    /// Talk to Jarvis: the island opens on the voice panel, with the keyboard
    /// (it has a text field).
    func openVoice() {
        open(.voice, reason: .typing)
    }

    func toggleVoice() {
        if isExpanded && ui.tab == .voice { close() } else { openVoice() }
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
        // Key only when you click into a text field (or open the chat by shortcut).
        panel.becomesKeyOnlyIfNeeded = true
        let root = IslandRootView(model: model, ui: ui, controller: self)
            .environment(\.layoutDirection, .leftToRight)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Nil while displays reconfigure (the screen list can be briefly empty).
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch Prefs.display {
        case .notch:
            return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
        case .menuBar:
            return screens.first ?? NSScreen.main
        case .followMouse:
            let mouse = NSEvent.mouseLocation
            return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens.first
        case .display(let uuid):
            return screens.first { Self.uuid(of: $0) == uuid }
                ?? screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
        }
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(num.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    func relocate() {
        guard let s = targetScreen() else { return }
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
        t.tolerance = interval == Self.idle ? 0.25 : interval == Self.near ? 0.01 : 0.004
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
        case .expanded: (w, h) = (IslandRootView.expandedWidth, IslandRootView.expandedHeight(model: model, tab: ui.tab,
                                                                                 topInset: ui.geometry.height + 8,
                                                                                 measured: ui.agentsMeasure))
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
        let keep = IslandVisibility.keepsPill(needsYou: !model.pending.isEmpty || model.waitingCount > 0,
                                              working: model.workingCount > 0,
                                              showWhileWorking: Prefs.showWhileWorking,
                                              alwaysShow: !Prefs.hideWhenIdle && model.connected)
        machine.tick(now: now, hovering: inIsland,
                     pinned: IslandPin.holds(pinned: ui.pinned, tab: ui.tab, pending: !model.pending.isEmpty),
                     hasSessions: keep)
        sync()
        let nearIsland = rect.offsetBy(dx: pf.minX, dy: pf.minY).insetBy(dx: -200, dy: -160).contains(mouse)
        let inBand = pf.insetBy(dx: -120, dy: -120).contains(mouse)
        let wanted = IslandTick.interval(expanded: machine.state == .expanded, nearIsland: nearIsland, inBand: inBand)
        if wanted != interval { start(interval: wanted) }
    }

    private func sync() {
        if ui.state != machine.state {
            let folding = ui.state == .expanded && machine.state != .expanded
            withAnimation(IslandRootView.morph) { ui.state = machine.state }
            // Voice is the orb's: whatever opens the island next opens your last tab.
            if folding && ui.tab == .voice { ui.tab = ui.lastTab }
            // Folded: hand the keyboard back to the app you were in.
            if machine.state != .expanded, panel.isKeyWindow { panel.resignKey() }
        }
    }
}

/// Lets the island sit in the menu bar / notch area and take key focus for text.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

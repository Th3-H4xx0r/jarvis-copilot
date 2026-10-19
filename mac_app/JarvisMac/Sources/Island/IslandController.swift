import AppKit
import Observation
import SwiftUI

/// What the island views need from the window: its state and the notch size.
@MainActor
@Observable
final class IslandUI {
    var state: IslandStateMachine.State = .hidden
    /// The open island is being built, out of sight, before it springs open.
    var preparing = false
    var geometry = IslandGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: nil,
                                  auxiliaryRightWidth: nil, menuBarHeight: 37)
    var hovering = false
    /// Something the user is typing into (an approval note, a question's Other):
    /// the island stays open while it's set.
    var pinned = false
    /// The expanded island's tab (Agents, Chat, Music, Voice).
    var tab: IslandTab = .agents {
        didSet { if tab != .voice { lastTab = tab } }
    }
    /// The last tab that isn't Voice: what a click on the notch opens.
    private(set) var lastTab: IslandTab = .agents
    /// The Agents tab's limits card (the usage pills open it).
    var showLimits = false
    /// Voice as the small island under the notch (push to talk), not the stage.
    var voiceMini = false
    /// The open island's width: the small voice island is narrower.
    var expandedWidth: CGFloat {
        tab == .voice && voiceMini ? IslandLayout.voiceMiniWidth : IslandRootView.expandedWidth
    }
    /// The Agents tab's measured parts (nil until its first layout).
    var agentsTop: CGFloat?
    var agentsList: CGFloat?
    var agentsMeasure: IslandMeasure? {
        guard let agentsTop, let agentsList else { return nil }
        return IslandMeasure(top: agentsTop, list: agentsList)
    }
    var compactWidth: CGFloat { geometry.width + 2 * IslandController.earWidth }

    // MARK: the orb's flight
    // The notch's small orb flies into the open island and becomes its big orb,
    // and back as the island folds. IslandViews draws it (`FlyingOrb`) over
    // both; the orbs at either end step aside while it's in the air.

    struct OrbFlight: Equatable {
        var direction: OrbFlightPlan.Direction
        var home: OrbHome
        /// A back flight leaves from where the orb sat (the tab changes as the island folds).
        var from: CGRect?
        /// An out flight sets off once its home has laid out.
        var launched: Bool
        var serial: Int
    }

    /// The notch's orb, in island coordinates (measured while folded).
    var orbEar: CGRect?
    /// Where the orb sits in the open island, per home (measured as each lays out).
    var orbHomes: [OrbHome: CGRect] = [:]
    var orbFlight: OrbFlight?
    /// Where the orb is: 0 at the ear (folded), 1 at home (open); the out spring
    /// swells it a little past 1. Never reset at a flight's start — each flight
    /// leaves from where the last left it (a reset and the spring in one update
    /// cancel out, and the orb jumps). States reached without a flight snap it
    /// to rest (`restOrb`), in an update of their own.
    var orbProgress: CGFloat = 0
    /// Hides (true) or shows the voice panel's own orb — the dylib's hand-off.
    /// Returns false when the panel can't (an older dylib): Voice then opens
    /// without a flight rather than with two orbs.
    @ObservationIgnored var setVoiceOrbHidden: ((Bool) -> Bool)?
    @ObservationIgnored private var flightSerial = 0

    var hidesEar: Bool { orbFlight != nil }
    func hidesOrb(_ home: OrbHome) -> Bool { orbFlight?.home == home }

    /// Start a flight for the current tab's orb.
    func flyOrb(_ direction: OrbFlightPlan.Direction) {
        let home = OrbHome.of(tab)
        guard orbEar != nil else { return restOrb(open: direction == .out) }
        if home == .voice, setVoiceOrbHidden?(true) != true { return restOrb(open: direction == .out) }
        flightSerial += 1
        let serial = flightSerial
        switch direction {
        case .out:
            orbFlight = OrbFlight(direction: .out, home: home, from: nil, launched: false, serial: serial)
            if orbHomes[home] != nil {
                launchOrb()
            } else {
                after(OrbFlightPlan.homeWait) { $0.abandonOrbFlight(serial: serial) }
            }
        case .back:
            guard let from = orbHomes[home] else {
                if home == .voice { _ = setVoiceOrbHidden?(false) }
                return restOrb(open: false)
            }
            orbFlight = OrbFlight(direction: .back, home: home, from: from, launched: true, serial: serial)
            withAnimation(OrbFlightPlan.backSpring) { orbProgress = 0 }
            after(OrbFlightPlan.backLanding) { $0.landOrb(serial: serial) }
        }
    }

    /// A home laid out (or moved): an out flight waiting on it sets off.
    func reportOrbHome(_ home: OrbHome, _ rect: CGRect) {
        guard rect.width > 0 else { return }
        orbHomes[home] = rect
        if let f = orbFlight, f.direction == .out, f.home == home, !f.launched { launchOrb() }
    }

    /// The flight is over: the orb in its place shows again.
    func landOrb(serial: Int) {
        guard let f = orbFlight, f.serial == serial else { return }
        withAnimation(.easeOut(duration: 0.12)) { orbFlight = nil }
        if f.home == .voice { _ = setVoiceOrbHidden?(false) }
    }

    /// Home never laid out: put the orbs back.
    func abandonOrbFlight(serial: Int) {
        guard let f = orbFlight, f.serial == serial, !f.launched else { return }
        landOrb(serial: serial)
        setProgress(1)
    }

    /// The island opened or folded without a flight (from hidden, Reduce
    /// Motion, nothing to fly from): the orb is simply where that state keeps it.
    func restOrb(open: Bool) {
        if let f = orbFlight {
            orbFlight = nil
            if f.home == .voice { _ = setVoiceOrbHidden?(false) }
        }
        setProgress(open ? 1 : 0)
    }

    private func launchOrb() {
        guard var f = orbFlight else { return }
        f.launched = true
        orbFlight = f
        let serial = f.serial
        withAnimation(OrbFlightPlan.outSpring) { orbProgress = 1 }
        after(OrbFlightPlan.outLanding) { $0.landOrb(serial: serial) }
    }

    private func setProgress(_ value: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { orbProgress = value }
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor (IslandUI) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self { body(self) }
        }
    }
}

extension OrbFlightPlan {
    /// Out: a touch of bounce, so it lands with a small swell. Back: quick and
    /// settled, so it tucks into the notch without wobbling.
    static let outSpring = Animation.spring(response: 0.46, dampingFraction: 0.74)
    static let backSpring = Animation.spring(response: 0.32, dampingFraction: 0.92)
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
    /// Push to talk held on another display: the island is there until it folds.
    private var talkScreen: NSScreen?
    private var talkScreenSerial = 0
    /// Bumped by every Voice open: a push-to-talk fold only folds its own talk.
    private var talkSerial = 0

    private static let fast = IslandTick.fast
    private static let near = IslandTick.near
    private static let idle = IslandTick.idle
    private var moveMonitor: Any?
    private var rightClickMonitor: Any?

    /// The voice panel for the Voice view (JarvisMenu loads it from the dylib).
    var voicePanel: (() -> NSViewController?)?
    /// The small voice island's view, from the same dylib (push to talk).
    var voiceMiniPanel: (() -> NSViewController?)?
    /// A right-click on the island: the menu (JarvisMenu), at that point.
    var onMenu: ((NSView, NSPoint) -> Void)?
    /// The open island folded (clicked away, closed, timed out).
    var onFolded: (() -> Void)?
    /// The screen the island is on.
    var currentScreen: NSScreen? { screen }

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
                guard let self, IslandClicks.foldsOnClickElsewhere(expanded: self.machine.state == .expanded,
                                                                   filePanelOpen: IslandClicks.filePanelOpen())
                else { return }
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
    /// (it has a text field). `mini` (push to talk): the small voice island,
    /// and the app you're in keeps the keyboard — unless the full stage is
    /// already open, which stays.
    func openVoice(mini: Bool = false) {
        talkSerial += 1
        if mini {
            if !(isExpanded && ui.tab == .voice && !ui.voiceMini) { ui.voiceMini = true }
            open(.voice, reason: .attention)
        } else {
            ui.voiceMini = false
            open(.voice, reason: .typing)
        }
    }

    /// The small voice island to the full stage (a click on it).
    func expandVoice() {
        withAnimation(IslandRootView.morph) { ui.voiceMini = false }
    }

    /// A push-to-talk answer is done: the small island folds a moment later
    /// (not while the pointer is on it, and not if you've talked again).
    func talkDone() {
        let serial = talkSerial
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, self.talkSerial == serial, self.isExpanded,
                      self.ui.tab == .voice, self.ui.voiceMini else { return }
                if !self.ui.hovering { self.close(); return }
            }
        }
    }

    /// Push to talk: the island comes to the display the pointer is on (and
    /// goes home when it folds). Returns that display.
    @discardableResult
    func comeToPointer(at point: CGPoint? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        guard let i = TalkScreen.index(of: point ?? NSEvent.mouseLocation, in: screens.map(\.frame)) else { return screen }
        let s = screens[i]
        talkScreenSerial += 1
        let home = targetScreen()
        talkScreen = s == home ? nil : s
        if s != screen { relocate() }
        return s
    }

    /// Folded on a talk's display: home again once the fold has played.
    private func goHomeAfterFold() {
        guard talkScreen != nil else { return }
        let serial = talkScreenSerial
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard let self, self.talkScreenSerial == serial, !self.isExpanded else { return }
            self.talkScreen = nil
            self.relocate()
        }
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
        let talk = talkScreen.flatMap { t in NSScreen.screens.contains(t) ? t : nil }
        guard let s = talk ?? targetScreen() else { return }
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

    /// The open island has been built (out of sight): once it is laid out and
    /// drawn, it springs open. A timer, not `async`: a queued block can run
    /// before the run loop's display flush, a timer only after it.
    func openBuilt() {
        guard ui.preparing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.springOpen() }
    }

    private func springOpen() {
        guard ui.preparing else { return }
        ui.preparing = false
        sync(built: true)
    }

    private func sync(built: Bool = false) {
        // Folded again before it opened: it leaves Voice as a fold does.
        if ui.preparing && machine.state != .expanded {
            ui.preparing = false
            if ui.tab == .voice { ui.tab = ui.lastTab }
        }
        if ui.state != machine.state {
            // Opening: build the open island first and spring once it's built
            // (openBuilt). Built in the spring's first frame, a tab held that
            // frame up to ~100 ms and the island lurched open.
            if machine.state == .expanded && !built {
                if !ui.preparing {
                    ui.preparing = true
                    // Never left waiting if the build doesn't report (the screen asleep).
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(0.3))
                        self?.springOpen()
                    }
                }
                return
            }
            let folding = ui.state == .expanded && machine.state != .expanded
            if folding { onFolded?(); goHomeAfterFold() }
            let flight = OrbFlightPlan.direction(
                from: ui.state, to: machine.state,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            withAnimation(IslandRootView.morph) { ui.state = machine.state }
            // The orb flies with the shape — before a fold resets the tab, so a
            // back flight leaves from the tab it was on.
            if let flight { ui.flyOrb(flight) } else { ui.restOrb(open: machine.state == .expanded) }
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

/// Which clicks elsewhere fold the open island. Not those while a file picker
/// of ours is up: its insides run in another process, so a click on a file
/// arrives as a click outside Jarvis.
enum IslandClicks {
    static func foldsOnClickElsewhere(expanded: Bool, filePanelOpen: Bool) -> Bool {
        expanded && !filePanelOpen
    }

    @MainActor
    static func filePanelOpen() -> Bool {
        NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible }
    }
}

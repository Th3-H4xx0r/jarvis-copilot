import SwiftUI
import UIKit

// The Mac live view's Command Center: the Mac's Control Center switches, its
// power (Unlock / Lock / Sleep / Keep awake), shortcuts, displays and open apps.
// Switches go over the share's own data channel (`MacScreenSession.command`, Mac
// side mac_app/JarvisMac/Sources/Screen/MacControls.swift); Unlock, Sleep and Keep
// awake go through the server like the Agents → Mac card (Face ID for Unlock).

// MARK: - What the Mac reports

/// The Mac's switches from its last `cc_state` (nil = it didn't say).
struct MacControlState: Equatable {
    var wifi: Bool?
    var wifiName: String?
    var bluetooth: Bool?
    var dark: Bool?
    var stage: Bool?
    var volume: Double?
    var muted: Bool?
    var brightness: Double?
    var locked: Bool?
    var nowTitle: String?
    var nowArtist: String?
    var nowPlaying: Bool?
    var displays: [MacDisplay] = []
    var display: Int?

    init() {}

    init(json: [String: Any]) {
        wifi = json["wifi"] as? Bool
        wifiName = json["wifi_name"] as? String
        bluetooth = json["bluetooth"] as? Bool
        dark = json["dark"] as? Bool
        stage = json["stage"] as? Bool
        volume = (json["volume"] as? NSNumber)?.doubleValue
        muted = json["muted"] as? Bool
        brightness = (json["brightness"] as? NSNumber)?.doubleValue
        locked = json["locked"] as? Bool
        if let now = json["now"] as? [String: Any] {
            nowTitle = now["title"] as? String
            nowArtist = now["artist"] as? String
            nowPlaying = now["playing"] as? Bool
        }
        displays = (json["displays"] as? [[String: Any]] ?? []).compactMap(MacDisplay.init(json:))
        display = (json["display"] as? NSNumber)?.intValue
    }

    /// A switch's second line: "On" / "Off", or a dash before the Mac said.
    static func onOff(_ value: Bool?, on: String = "On") -> String {
        guard let value else { return "—" }
        return value ? on : "Off"
    }
}

struct MacDisplay: Identifiable, Equatable {
    let id: Int
    let name: String
    let main: Bool

    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Display"
        main = json["main"] as? Bool ?? false
    }

    /// "Built-in Retina Display" → "Built-in"; others keep their own name.
    var shortName: String { name.hasPrefix("Built-in") ? "Built-in" : name }
}

struct MacApp: Identifiable, Equatable {
    let pid: Int
    let name: String
    let bundle: String
    let active: Bool

    var id: Int { pid }

    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.intValue, let name = json["name"] as? String else { return nil }
        self.pid = pid
        self.name = name
        bundle = json["bundle"] as? String ?? ""
        active = json["active"] as? Bool ?? false
    }

    /// The apps in a `cc_apps` message, in the Mac's order; an entry without a pid or name is skipped.
    static func list(from message: [String: Any]) -> [MacApp] {
        (message["apps"] as? [[String: Any]] ?? []).compactMap(MacApp.init(json:))
    }
}

/// What the open-apps switcher shows. It is never a blank box: while the Mac hasn't
/// answered it says so, and a Mac app that never answers Command Center requests
/// (an old build still running) gets told how to fix it.
enum MacAppSwitcherContent: Equatable {
    case connecting
    case loading
    case macTooOld
    case failed(String)
    case empty
    case apps([MacApp])

    /// How long the switcher waits for the Mac before saying it isn't answering.
    static let patience: Duration = .seconds(6)

    static func resolve(live: Bool, apps: [MacApp], appsLoaded: Bool, controlsLoaded: Bool,
                        error: String?, waitedOut: Bool) -> MacAppSwitcherContent {
        if !apps.isEmpty { return .apps(apps) }
        if appsLoaded { return .empty }
        guard live else { return .connecting }
        if let error, !error.isEmpty, waitedOut { return .failed(error) }
        guard waitedOut else { return .loading }
        // The Mac answered with its switches but not its apps, or not at all: the second
        // is the Jarvis Mac app from before the Command Center, which ignores these requests.
        return controlsLoaded ? .failed("Your Mac didn't send its open apps. Try again.") : .macTooOld
    }

    var message: String? {
        switch self {
        case .connecting: return "Connecting to your Mac…"
        case .loading: return "Asking your Mac for its open apps…"
        case .macTooOld: return "Your Mac isn't answering. Quit Jarvis on the Mac and open it again (or update it), then try again."
        case .failed(let why): return why
        case .empty: return "No apps are open on your Mac."
        case .apps: return nil
        }
    }
}

/// A keyboard shortcut sent as a key event (InputInjector on the Mac).
struct MacShortcut: Identifiable {
    let title: String
    let symbol: String
    let key: String
    let mods: [String]
    var id: String { title }

    /// "Switch App" opens the phone's list of the Mac's open apps. Sent as ⌘Tab it left the
    /// Mac's own switcher up, waiting for a ⌘ release that a remote key press never has.
    var opensAppSwitcher: Bool { key == "Tab" && mods == ["cmd"] }

    static let all: [MacShortcut] = [
        MacShortcut(title: "Spotlight", symbol: "magnifyingglass", key: "space", mods: ["cmd"]),
        MacShortcut(title: "Switch App", symbol: "command", key: "Tab", mods: ["cmd"]),
        MacShortcut(title: "Copy", symbol: "doc.on.doc", key: "c", mods: ["cmd"]),
        MacShortcut(title: "Paste", symbol: "doc.on.clipboard", key: "v", mods: ["cmd"]),
        MacShortcut(title: "Undo", symbol: "arrow.uturn.backward", key: "z", mods: ["cmd"]),
        MacShortcut(title: "Close Window", symbol: "xmark.square", key: "w", mods: ["cmd"]),
        MacShortcut(title: "Screenshot", symbol: "camera.viewfinder", key: "5", mods: ["cmd", "shift"]),
        MacShortcut(title: "Force Quit", symbol: "exclamationmark.octagon", key: "Escape", mods: ["cmd", "alt"]),
    ]
}

// MARK: - Landscape

/// The app is portrait; the Mac viewer alone also turns to landscape.
@MainActor
enum MacScreenOrientation {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func allowLandscape(_ on: Bool) {
        mask = on ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            vc?.setNeedsUpdateOfSupportedInterfaceOrientations()
            while let next = vc?.presentedViewController {
                next.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = next
            }
        }
        if !on { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
    }
}

extension AppDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { MacScreenOrientation.mask }
    }
}

// MARK: - The sheet

/// Every Command Center item (`MacControlItem`), in sections. Taps go through the live view's
/// `MacControlActions`, the same path the pinned strip under the picture uses.
struct MacCommandCenterSheet: View {
    let session: MacScreenSession
    @Environment(\.dismiss) private var dismiss

    private var actions: MacControlActions { session.controlActions }
    private var c: MacControlState { session.controls }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !session.controlsLoaded {
                        notice("Waiting for your Mac… If this stays, update Jarvis on the Mac.")
                    }
                    if let why = session.controlError ?? actions.powerError {
                        notice(why, danger: true)
                    }
                    if c.locked == true { lockedCard.padding(.top, 8) }
                    JcSectionLabel("Controls", first: true)
                    switches
                    MacNowPlayingCard(actions: actions, face: actions.face(.nowPlaying)).padding(.top, 10)
                    sliders.padding(.top, 10)
                    if c.displays.count > 1 { displays }
                    JcSectionLabel("Mac")
                    power
                    JcSectionLabel("Shortcuts")
                    shortcuts
                    JcSectionLabel("Open apps")
                    MacAppSwitcher(session: session, layout: .grid) { dismiss() }
                }
                .padding(.horizontal, JcUnified.pageInset)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .jcScreen("Command Center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationBackground(.black)
        .onAppear {
            session.command("state")
            Task { await actions.refreshMac() }
        }
        .macControlPrompts(actions, session: session) { dismiss() }
    }

    // MARK: sections

    private func notice(_ text: String, danger: Bool = false) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: danger ? "exclamationmark.triangle.fill" : "hourglass")
        }
        .font(.footnote)
        .foregroundStyle(danger ? JcTheme.danger : JcTheme.muted)
        .padding(.top, 8)
    }

    private var lockedCard: some View {
        JcCard {
            HStack(spacing: 12) {
                JcIconSquare(symbol: "lock.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Mac is locked").font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                    Text("Unlock it with Face ID").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 8)
                Button { actions.perform(.unlock) } label: {
                    if actions.busy == "unlock" { ProgressView().controlSize(.small) } else { Text("Unlock") }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(actions.busy != nil)
            }
        }
    }

    private var switches: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(MacControlItem.switches) { item in
                MacTile(face: actions.face(item)) {
                    actions.perform(item)
                    // The Mac's own Control Center opened: tap the switch there, in the live view.
                    if item.opensMacControlCenter { dismiss() }
                }
            }
        }
    }

    private var sliders: some View {
        JcCard {
            VStack(alignment: .leading, spacing: 16) {
                if actions.isAvailable(.display) { MacSliderRow(item: .display, actions: actions) }
                MacSliderRow(item: .sound, actions: actions)
            }
        }
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Display shared")
            JcSegmentedPicker(c.displays.map { (value: $0.id, label: $0.shortName) },
                              selection: Binding(get: { c.display ?? c.displays.first?.id ?? 0 },
                                                 set: { id in
                                                     session.command("display", ["id": id]) { $0.display = id }
                                                 }))
        }
    }

    private var power: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach([MacControlItem.unlock, .lock, .sleep]) { item in
                    Button { actions.perform(item) } label: {
                        HStack(spacing: 7) {
                            if actions.busy == item.rawValue { ProgressView().controlSize(.small) } else { Image(systemName: item.symbol) }
                            Text(item.title).lineLimit(1)
                        }
                    }
                    .buttonStyle(MacActionButtonStyle(prominent: item == .unlock && c.locked == true))
                    .disabled(actions.busy != nil)
                }
            }
            if let mac = actions.mac {
                JcCard(padding: 0) {
                    JcRow(symbol: MacControlItem.keepAwake.symbol, title: MacControlItem.keepAwake.title,
                          subtitle: AgentsMacPowerCopy.keepAwakeSubtitle(on: mac.keepAwake), last: true) {
                        Toggle("Keep awake", isOn: Binding(get: { mac.keepAwake },
                                                           set: { on in actions.run(.keepAwake(on)) }))
                            .labelsHidden()
                            .tint(JcTheme.accent)
                    }
                }
            }
        }
    }

    private var shortcuts: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(MacControlItem.shortcuts) { item in
                MacSquare(symbol: item.symbol, title: item.title) { actions.perform(item) }
            }
        }
    }
}

/// Now Playing: what plays, and previous / play-pause / next.
struct MacNowPlayingCard: View {
    let actions: MacControlActions
    let face: MacControlItem.Face

    var body: some View {
        JcCard {
            HStack(spacing: 12) {
                JcIconSquare(symbol: face.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.title)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(1)
                    Text(face.subtitle ?? "")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                MacTransport(actions: actions, playing: face.on, size: 17, width: 36)
            }
        }
    }
}

/// Previous, play/pause, next: media keys on the Mac.
struct MacTransport: View {
    let actions: MacControlActions
    let playing: Bool
    var size: CGFloat = 17
    var width: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            button("backward.fill", "previous", label: "Previous")
            button(playing ? "pause.fill" : "play.fill", "play", label: "Play or pause")
            button("forward.fill", "next", label: "Next")
        }
    }

    private func button(_ symbol: String, _ key: String, label: String) -> some View {
        Button { actions.media(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Display brightness or Sound: the title, the slider, its end icons (Sound's low end mutes).
struct MacSliderRow: View {
    let item: MacControlItem
    @Bindable var actions: MacControlActions
    var showsTitle = true
    @State private var editing = false

    private var current: Double { item == .sound ? actions.volume : actions.brightness }
    private var kind: MacControlActions.Slider { item == .sound ? .volume : .brightness }

    var body: some View {
        let face = actions.face(item)
        let sound = item == .sound
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
            }
            HStack(spacing: 10) {
                Button { if sound { actions.toggleMute() } } label: {
                    Image(systemName: sound ? (face.subtitle == "Muted" ? "speaker.slash.fill" : "speaker.fill") : "sun.min")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!sound)
                .accessibilityLabel(sound ? "Mute" : item.title)
                // Only his drags go to the Mac: the Mac's own reports move the slider without an echo
                // (a volume echo would also unmute it).
                Slider(value: sound ? $actions.volume : $actions.brightness, in: sound ? 0...100 : 0...1) { on in
                    editing = on
                    if !on { actions.slide(kind, to: current) }
                }
                .tint(JcTheme.accent)
                .onChange(of: current) { _, v in if editing { actions.slide(kind, to: v) } }
                .accessibilityLabel(item.title)
                Image(systemName: sound ? "speaker.wave.3.fill" : "sun.max.fill")
                    .frame(width: 24, height: 24).accessibilityHidden(true)
            }
            .font(.system(size: 14))
            .foregroundStyle(JcTheme.muted)
        }
    }
}

// MARK: - Pieces

/// A Control Center switch: the round icon (accent when on), its name and state,
/// on the app's card surface.
private struct MacTile: View {
    let face: MacControlItem.Face
    let action: () -> Void

    private var symbol: String { face.symbol }
    private var title: String { face.title }
    private var subtitle: String { face.subtitle ?? "" }
    private var on: Bool { face.on }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Color.black : JcTheme.text)
                    .frame(width: 34, height: 34)
                    .background(on ? JcTheme.accent : Color.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(JcTheme.glassFill, in: shape)
            .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
            .contentShape(shape)
            .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}

/// A shortcut: an icon square with its name under it.
private struct MacSquare: View {
    let symbol: String
    let title: String
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(JcTheme.glassFill, in: shape)
                    .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// An open app's icon (its initial until the Mac sends the icon), with the
/// Dock's dot under the frontmost one.
struct MacAppIcon: View {
    let app: MacApp
    let image: UIImage?
    var side: CGFloat = 44
    var showsActiveDot = true

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Text(String(app.name.prefix(1)))
                    .font(.system(size: side * 0.4, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottom) {
            if app.active && showsActiveDot {
                Circle().fill(JcTheme.text).frame(width: 4, height: 4).offset(y: 7)
            }
        }
    }
}

/// The Mac's open apps to switch to (Command Center, the Switch App sheet and the landscape
/// rail), or what is going on when there are none yet — never a blank box. Opening it asks
/// the Mac again, so a list missed while the channel opened still arrives. Long-press an icon
/// for its Dock menu (a popover; in the rail's column, the column itself turns into the menu).
struct MacAppSwitcher: View {
    enum Layout { case grid, column }

    let session: MacScreenSession
    var layout: Layout = .grid
    var picked: () -> Void = {}
    @State private var waitedOut = false
    @State private var attempt = 0
    @State private var menuApp: MacApp?

    private var live: Bool { session.phase == .live }

    private var content: MacAppSwitcherContent {
        .resolve(live: live, apps: session.apps, appsLoaded: session.appsLoaded,
                 controlsLoaded: session.controlsLoaded, error: session.controlError, waitedOut: waitedOut)
    }

    var body: some View {
        Group {
            if layout == .column, let app = menuApp {
                MacDockMenu(session: session, app: app, back: { menuApp = nil }) { showsMac in
                    menuApp = nil
                    if showsMac { picked() }
                }
            } else if case .apps(let apps) = content {
                switch layout {
                case .grid: grid(apps)
                case .column: column(apps)
                }
            } else {
                notice(content)
            }
        }
        .task(id: "\(live)-\(attempt)") {
            guard live else { return }
            waitedOut = false
            session.refreshApps()
            try? await Task.sleep(for: MacAppSwitcherContent.patience)
            if !Task.isCancelled { waitedOut = true }
        }
    }

    private func notice(_ content: MacAppSwitcherContent) -> some View {
        let waiting = content == .loading || content == .connecting
        let retry: Bool
        switch content {
        case .macTooOld, .failed: retry = true
        default: retry = false
        }
        return VStack(alignment: layout == .grid ? .leading : .center, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: content == .empty ? "macwindow" : "exclamationmark.triangle")
                        .foregroundStyle(JcTheme.muted)
                }
                Text(content.message ?? "")
                    .font(.footnote)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if retry {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.jcGlass(compact: true))
            }
        }
        .frame(maxWidth: layout == .grid ? .infinity : 240, alignment: .leading)
        .padding(layout == .grid ? 0 : 16)
        .padding(.vertical, layout == .grid ? 4 : 0)
        .accessibilityElement(children: .combine)
    }

    private func grid(_ apps: [MacApp]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
        return LazyVGrid(columns: cols, spacing: 16) {
            ForEach(apps) { app in
                VStack(spacing: 10) {
                    MacAppIcon(app: app, image: session.appIcons[app.bundle])
                    Text(app.name).font(.system(size: 10)).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .macAppIconPress(name: "Switch to \(app.name)", tap: { pick(app) }, menu: { menuApp = app })
                .macDockMenuPopover(session: session, app: app, shown: $menuApp) { showsMac in
                    if showsMac { picked() }
                }
            }
        }
    }

    private func column(_ apps: [MacApp]) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 16) {
                ForEach(apps) { app in
                    MacAppIcon(app: app, image: session.appIcons[app.bundle], side: 44)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                        .macAppIconPress(name: "Switch to \(app.name)", tap: { pick(app) }, menu: { menuApp = app })
                }
            }
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.vertical, 18, for: .scrollContent)
        .scrollIndicators(.hidden)
        .frame(width: 84, height: min(340, CGFloat(apps.count) * 66 + 36))
    }

    private func pick(_ app: MacApp) {
        session.command("app", ["pid": app.pid])
        picked()
    }
}

/// "Switch App": the Mac's open apps on the phone, tap one to bring it forward.
struct MacAppSwitcherSheet: View {
    let session: MacScreenSession
    let picked: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MacAppSwitcher(session: session, layout: .grid, picked: picked)
                    .padding(.horizontal, JcUnified.pageInset)
                    .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .jcScreen("Switch app", header: .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
    }
}

/// The open apps as a Dock-like strip along the bottom in portrait (shown once the Mac sent them).
/// Tap switches; long-press (or right-click) opens the app's Dock menu.
struct MacAppStrip: View {
    let session: MacScreenSession
    var side: CGFloat = 40
    @State private var menuApp: MacApp?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) { icons }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var icons: some View {
        ForEach(session.apps) { app in
            MacAppIcon(app: app, image: session.appIcons[app.bundle], side: side)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .macAppIconPress(name: "Switch to \(app.name)",
                                 tap: { session.command("app", ["pid": app.pid]) },
                                 menu: { menuApp = app })
                .macDockMenuPopover(session: session, app: app, shown: $menuApp)
        }
    }
}

extension View {
    /// The app's Dock menu as a popover from its icon, while `shown` is that app.
    func macDockMenuPopover(session: MacScreenSession, app: MacApp, shown: Binding<MacApp?>,
                            done: @escaping (Bool) -> Void = { _ in }) -> some View {
        popover(isPresented: Binding(get: { shown.wrappedValue?.pid == app.pid },
                                     set: { if !$0, shown.wrappedValue?.pid == app.pid { shown.wrappedValue = nil } }),
                arrowEdge: .bottom) {
            MacDockMenu(session: session, app: app) { showsMac in
                shown.wrappedValue = nil
                done(showsMac)
            }
            .presentationCompactAdaptation(.popover)
            .presentationBackground(JcTheme.surface)
        }
    }
}

/// Landscape: the slim column of controls to the right of the Mac's screen.
struct MacScreenRail: View {
    let session: MacScreenSession
    @Binding var showCenter: Bool
    @Binding var keyboard: Bool
    let close: () -> Void
    @State private var showApps = false
    /// The pinned-controls popover is open (it then presents Unlock's Face ID itself).
    @Binding var showControls: Bool

    var body: some View {
        VStack(spacing: 8) {
            railButton("xmark", label: "Done", action: close)
            Spacer(minLength: 6)
            railButton("switch.2", label: "Command Center") { showCenter = true }
            railButton("square.grid.2x2", label: "Open apps") { showApps = true }
                .popover(isPresented: $showApps, arrowEdge: .trailing) {
                    MacAppSwitcher(session: session, layout: .column) { showApps = false }
                        .presentationCompactAdaptation(.popover)
                }
            railButton("slider.horizontal.below.rectangle", label: "Pinned controls") { showControls = true }
                .popover(isPresented: $showControls, arrowEdge: .trailing) {
                    MacControlStrip(session: session, layout: .column)
                        .frame(width: 270)
                        .frame(maxHeight: 340)
                        .macControlPrompts(session.controlActions, session: session) { showControls = false }
                        .presentationCompactAdaptation(.popover)
                }
            railButton("keyboard", label: "Keyboard") { keyboard.toggle() }
            railButton(nil, text: "esc", label: "Escape") { session.send(["t": "key", "key": "Escape", "mods": [String]()]) }
            railButton("delete.left", label: "Delete") { session.send(["t": "key", "key": "Delete", "mods": [String]()]) }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 10)
        .frame(width: 64)
    }

    private func railButton(_ symbol: String?, text: String? = nil, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(text ?? "") }
            }
                .font(.system(size: symbol == nil ? 14 : 16, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .frame(width: 42, height: 42)
                .jcButtonSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

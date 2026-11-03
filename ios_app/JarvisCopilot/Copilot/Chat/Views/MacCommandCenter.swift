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
}

/// A keyboard shortcut sent as a key event (InputInjector on the Mac).
struct MacShortcut: Identifiable {
    let title: String
    let symbol: String
    let key: String
    let mods: [String]
    var id: String { title }

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

struct MacCommandCenterSheet: View {
    let session: MacScreenSession
    @Environment(\.dismiss) private var dismiss
    private let store = AgentsStore.shared
    @State private var volume: Double = 50
    @State private var brightness: Double = 0.5
    @State private var sendTask: Task<Void, Never>?
    @State private var powerError: String?
    @State private var busy: String?
    @State private var passwordRequest: MacPasswordRequest?
    @State private var taps = 0

    private var c: MacControlState { session.controls }
    private var mac: AgentMacPower? { store.macs.first(where: \.isAwake) ?? store.macs.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !session.controlsLoaded {
                        notice("Waiting for your Mac… If this stays, update Jarvis on the Mac.")
                    }
                    if let why = session.controlError ?? powerError {
                        notice(why, danger: true)
                    }
                    if c.locked == true { lockedCard.padding(.top, 8) }
                    JcSectionLabel("Controls", first: true)
                    switches
                    nowPlaying.padding(.top, 10)
                    sliders.padding(.top, 10)
                    if c.displays.count > 1 { displays }
                    JcSectionLabel("Mac")
                    power
                    JcSectionLabel("Shortcuts")
                    shortcuts
                    if !session.apps.isEmpty {
                        JcSectionLabel("Open apps")
                        MacAppGrid(session: session) { dismiss() }
                    }
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
            Task { await store.refresh() }
        }
        .onChange(of: c.volume, initial: true) { _, v in if let v, sendTask == nil { volume = v } }
        .onChange(of: c.brightness, initial: true) { _, b in if let b, sendTask == nil { brightness = b } }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sheet(item: $passwordRequest) { request in
            MacPasswordSheet(request: request,
                             macName: AgentsMacPowerCopy.macName(request.deviceId, in: store.macs),
                             answer: { allow in
                                 let error = await store.answerMacPassword(request, allow: allow)
                                 if error == nil { passwordRequest = nil }
                                 return error
                             },
                             expired: { passwordRequest = nil })
        }
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
                Button { unlock() } label: {
                    if busy == "unlock" { ProgressView().controlSize(.small) } else { Text("Unlock") }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(busy != nil)
            }
        }
    }

    private var switches: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            MacTile(symbol: "wifi", title: "Wi-Fi",
                    subtitle: MacControlState.onOff(c.wifi, on: c.wifiName ?? "On"), on: c.wifi == true) {
                let next = !(c.wifi ?? false)
                tap { session.command("wifi", ["on": next]) { $0.wifi = next } }
            }
            MacTile(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth",
                    subtitle: MacControlState.onOff(c.bluetooth), on: c.bluetooth == true) {
                let next = !(c.bluetooth ?? false)
                tap { session.command("bluetooth", ["on": next]) { $0.bluetooth = next } }
            }
            MacTile(symbol: "circle.lefthalf.filled", title: "Dark Mode",
                    subtitle: MacControlState.onOff(c.dark), on: c.dark == true) {
                let next = !(c.dark ?? false)
                tap { session.command("dark", ["on": next]) { $0.dark = next } }
            }
            MacTile(symbol: "squares.leading.rectangle", title: "Stage Manager",
                    subtitle: MacControlState.onOff(c.stage), on: c.stage == true) { openControlCenter() }
            MacTile(symbol: "airplayaudio", title: "AirDrop", subtitle: "On the Mac", on: false) {
                openControlCenter()
            }
            MacTile(symbol: "moon.fill", title: "Focus", subtitle: "On the Mac", on: false) {
                openControlCenter()
            }
            MacTile(symbol: "rectangle.on.rectangle", title: "Mirroring", subtitle: "On the Mac", on: false) { openControlCenter() }
            MacTile(symbol: "switch.2", title: "Control Center", subtitle: "On the Mac", on: false) {
                openControlCenter()
            }
        }
    }

    private var nowPlaying: some View {
        JcCard {
            HStack(spacing: 12) {
                JcIconSquare(symbol: "music.note")
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.nowTitle ?? "Now Playing")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(1)
                    Text(c.nowArtist.flatMap { $0.isEmpty ? nil : $0 } ?? "Controls whatever is playing")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                mediaButton("backward.fill", "previous")
                mediaButton(c.nowPlaying == true ? "pause.fill" : "play.fill", "play")
                mediaButton("forward.fill", "next")
            }
        }
    }

    private func mediaButton(_ symbol: String, _ key: String) -> some View {
        Button {
            tap { session.command("media", ["key": key]) { if key == "play" { $0.nowPlaying = !($0.nowPlaying ?? false) } } }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key == "play" ? "Play or pause" : key == "next" ? "Next" : "Previous")
    }

    private var sliders: some View {
        JcCard {
            VStack(alignment: .leading, spacing: 16) {
                if c.brightness != nil {
                    sliderRow("Display", low: "sun.min", high: "sun.max.fill", value: $brightness, range: 0...1) {
                        session.command("brightness", ["value": $0])
                    }
                }
                sliderRow("Sound", low: c.muted == true ? "speaker.slash.fill" : "speaker.fill",
                          high: "speaker.wave.3.fill", value: $volume, range: 0...100, lowTap: {
                              let next = !(c.muted ?? false)
                              tap { session.command("mute", ["on": next]) { $0.muted = next } }
                          }) {
                    session.command("volume", ["value": Int($0)])
                }
            }
        }
    }

    private func sliderRow(_ title: String, low: String, high: String, value: Binding<Double>,
                           range: ClosedRange<Double>, lowTap: (() -> Void)? = nil,
                           send: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
            HStack(spacing: 10) {
                Button { lowTap?() } label: { Image(systemName: low).frame(width: 24, height: 24) }
                    .buttonStyle(.plain)
                    .disabled(lowTap == nil)
                    .accessibilityLabel(lowTap == nil ? title : "Mute")
                Slider(value: value, in: range)
                    .tint(JcTheme.accent)
                    .onChange(of: value.wrappedValue) { _, v in debounce { send(v) } }
                    .accessibilityLabel(title)
                Image(systemName: high).frame(width: 24, height: 24).accessibilityHidden(true)
            }
            .font(.system(size: 14))
            .foregroundStyle(JcTheme.muted)
        }
    }

    /// One message per pause in a drag, never one per pixel.
    private func debounce(_ work: @escaping () -> Void) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            work()
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { sendTask = nil }
        }
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Display shared")
            JcSegmentedPicker(c.displays.map { (value: $0.id, label: $0.shortName) },
                              selection: Binding(get: { c.display ?? c.displays.first?.id ?? 0 },
                                                 set: { id in
                                                     tap { session.command("display", ["id": id]) { $0.display = id } }
                                                 }))
        }
    }

    private var power: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                powerButton("Unlock", symbol: "lock.open.fill", id: "unlock", prominent: c.locked == true) { unlock() }
                powerButton("Lock", symbol: "lock.fill", id: "lock") {
                    session.command("lock") { $0.locked = true }
                }
                powerButton("Sleep", symbol: "moon.zzz.fill", id: "sleep") { runPower(.letSleep, id: "sleep") }
            }
            if let mac {
                JcCard(padding: 0) {
                    JcRow(symbol: "cup.and.saucer", title: "Keep awake",
                          subtitle: AgentsMacPowerCopy.keepAwakeSubtitle(on: mac.keepAwake), last: true) {
                        Toggle("Keep awake", isOn: Binding(get: { mac.keepAwake },
                                                           set: { on in runPower(.keepAwake(on), id: "keep") }))
                            .labelsHidden()
                            .tint(JcTheme.accent)
                    }
                }
            }
        }
    }

    private func powerButton(_ title: String, symbol: String, id: String, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button { tap(action) } label: {
            HStack(spacing: 7) {
                if busy == id { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(MacActionButtonStyle(prominent: prominent))
        .disabled(busy != nil)
    }

    private var shortcuts: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        return LazyVGrid(columns: cols, spacing: 12) {
            MacSquare(symbol: "rectangle.3.group", title: "Mission Control") { tap { session.command("mission_control") } }
            MacSquare(symbol: "menubar.dock.rectangle", title: "Show Desktop") { tap { session.command("show_desktop") } }
            ForEach(MacShortcut.all) { s in
                MacSquare(symbol: s.symbol, title: s.title) {
                    tap { session.send(["t": "key", "key": s.key, "mods": s.mods]) }
                }
            }
        }
    }

    // MARK: actions

    private func tap(_ work: () -> Void) {
        taps += 1
        work()
    }

    /// AirDrop, Focus, Stage Manager and Mirroring: macOS lets no app switch them,
    /// so the Mac's own Control Center opens — tap the switch in the live view.
    private func openControlCenter() {
        tap { session.command("control_center") }
        dismiss()
    }

    private func runPower(_ action: AgentsStore.MacPowerAction, id: String) {
        guard let mac else { powerError = "Jarvis can't find your Mac on the server."; return }
        powerError = nil
        busy = id
        Task {
            powerError = await store.macPower(mac, action)
            busy = nil
        }
    }

    /// Unlock Mac: the server asks the Mac, the Mac asks for his yes (Face ID on
    /// this phone, the sheet), then types the password.
    private func unlock() {
        guard let mac else { powerError = "Jarvis can't find your Mac on the server."; return }
        powerError = nil
        busy = "unlock"
        Task {
            defer { busy = nil }
            if let error = await store.macPower(mac, .unlock) { powerError = error; return }
            for _ in 0..<20 {
                let mine = store.passwordRequests.filter { $0.deviceId == mac.deviceId }
                if let request = mine.first(where: { $0.kind == "unlock" }) ?? mine.first {
                    passwordRequest = request
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                await store.refresh()
            }
            powerError = "The Mac didn't ask to unlock. Is Jarvis running on it?"
        }
    }
}

// MARK: - Pieces

/// A Control Center switch: the round icon (accent when on), its name and state,
/// on the app's card surface.
private struct MacTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let on: Bool
    let action: () -> Void

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
            if app.active {
                Circle().fill(JcTheme.text).frame(width: 4, height: 4).offset(y: 7)
            }
        }
    }
}

/// The open apps in a grid (the Command Center): tap one to bring it forward.
private struct MacAppGrid: View {
    let session: MacScreenSession
    let picked: () -> Void

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(session.apps) { app in
                Button {
                    session.command("app", ["pid": app.pid])
                    picked()
                } label: {
                    VStack(spacing: 10) {
                        MacAppIcon(app: app, image: session.appIcons[app.bundle])
                        Text(app.name).font(.system(size: 10)).foregroundStyle(JcTheme.muted).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch to \(app.name)")
            }
        }
    }
}

/// The open apps as a Dock-like strip: along the bottom in portrait, in the
/// rail's popover in landscape.
struct MacAppStrip: View {
    let session: MacScreenSession
    var axis: Axis = .horizontal
    var side: CGFloat = 40
    var picked: () -> Void = {}

    var body: some View {
        ScrollView(axis == .horizontal ? .horizontal : .vertical) {
            if axis == .horizontal {
                HStack(spacing: 14) { icons }.padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                VStack(spacing: 16) { icons }.padding(14)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var icons: some View {
        ForEach(session.apps) { app in
            Button {
                session.command("app", ["pid": app.pid])
                picked()
            } label: {
                MacAppIcon(app: app, image: session.appIcons[app.bundle], side: side)
                    .padding(.bottom, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to \(app.name)")
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

    var body: some View {
        VStack(spacing: 12) {
            railButton("xmark", label: "Done", action: close)
            Spacer(minLength: 6)
            railButton("switch.2", label: "Command Center") { showCenter = true }
            railButton("square.grid.2x2", label: "Open apps") { showApps = true }
                .popover(isPresented: $showApps, arrowEdge: .trailing) {
                    MacAppStrip(session: session, axis: .vertical, side: 44) { showApps = false }
                        .frame(width: 84, height: 320)
                        .presentationCompactAdaptation(.popover)
                }
            railButton("keyboard", label: "Keyboard") { keyboard.toggle() }
            railButton(nil, text: "esc", label: "Escape") { session.send(["t": "key", "key": "Escape", "mods": [String]()]) }
            railButton("delete.left", label: "Delete") { session.send(["t": "key", "key": "Delete", "mods": [String]()]) }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 12)
        .frame(width: 64)
        .onAppear { if session.apps.isEmpty { session.command("state") } }
    }

    private func railButton(_ symbol: String?, text: String? = nil, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(text ?? "") }
            }
                .font(.system(size: symbol == nil ? 14 : 16, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .frame(width: 44, height: 44)
                .jcLiquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

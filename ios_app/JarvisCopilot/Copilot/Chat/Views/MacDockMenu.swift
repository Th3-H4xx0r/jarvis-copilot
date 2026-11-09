import SwiftUI
import UIKit

// The Mac Dock's right-click menu for an open app, on the phone: "I would like to press and hold
// the icons of open apps to see menu for them … if I have multiple vsc windows, I can't switch it
// from the iOS app". Long-press (or right-click with a pointer) an app icon in the live view: its
// open windows by title (tap one → that exact window comes to the front), then New Window, Show
// All Windows, Hide and Quit. Mac side: MacControls.swift ("windows", "window", "app_*") and
// MacWindows.swift.

// MARK: - What the Mac reports

struct MacWindow: Identifiable, Equatable {
    /// The Mac's window number (negative: its position, when macOS gave no number).
    let id: Int
    let title: String
    let minimized: Bool
    /// The app's main window (the Dock's checkmark).
    let front: Bool

    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        title = json["title"] as? String ?? ""
        minimized = json["min"] as? Bool ?? false
        front = json["front"] as? Bool ?? false
    }

    var label: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled window" : title }
}

/// One app's windows from a `cc_windows` reply.
struct MacAppWindows: Equatable {
    let pid: Int
    let windows: [MacWindow]
    /// The app has a New Window menu item.
    let canNewWindow: Bool
    /// False: the Mac's Jarvis has no Accessibility permission, so it can't see windows.
    let accessibility: Bool

    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.intValue else { return nil }
        self.pid = pid
        windows = (json["windows"] as? [[String: Any]] ?? []).compactMap(MacWindow.init(json:))
        canNewWindow = json["new_window"] as? Bool ?? false
        accessibility = json["ax"] as? Bool ?? true
    }
}

/// Whether the Mac's Jarvis answers window requests (a build from before the Dock menu doesn't).
enum MacWindowSupport: Equatable { case unknown, yes, no }

// MARK: - The menu's actions

enum MacDockAction: String, CaseIterable, Identifiable {
    case newWindow, showAll, hide, quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .showAll: return "Show All Windows"
        case .hide: return "Hide"
        case .quit: return "Quit"
        }
    }

    var symbol: String {
        switch self {
        case .newWindow: return "plus.rectangle.on.rectangle"
        case .showAll: return "rectangle.3.group"
        case .hide: return "eye.slash"
        case .quit: return "xmark.circle"
        }
    }

    /// What goes to the Mac. An updated Mac gets the action itself; an older one only what it can
    /// do safely: bring the app forward, and ⌘H for Hide (harmless if it lands elsewhere). Never a
    /// ⌘Q or ⌘N guessed after an activation that may not have happened.
    func steps(pid: Int, updatedMac: Bool) -> [MacDockStep] {
        if updatedMac {
            switch self {
            case .newWindow: return [.cc("app_new_window", pid: pid)]
            case .showAll: return [.cc("app_show_all", pid: pid)]
            case .hide: return [.cc("app_hide", pid: pid)]
            case .quit: return [.cc("app_quit", pid: pid)]
            }
        }
        switch self {
        case .showAll: return [.cc("app", pid: pid)]
        case .hide: return [.cc("app", pid: pid), .key("h", mods: ["cmd"])]
        case .newWindow, .quit: return []
        }
    }
}

/// One message of a Dock menu action, over the share's "input" channel.
enum MacDockStep: Equatable {
    case cc(String, pid: Int)
    case raise(pid: Int, window: Int)
    /// A key press, sent after the app had a moment to come forward.
    case key(String, mods: [String])

    var message: [String: AnyHashable] {
        switch self {
        case .cc(let action, let pid): return ["t": "cc", "do": action, "pid": pid]
        case .raise(let pid, let window): return ["t": "cc", "do": "window", "pid": pid, "id": window]
        case .key(let key, let mods): return ["t": "key", "key": key, "mods": mods]
        }
    }
}

/// What the menu shows: the windows (or why there are none) and the actions that will work.
struct MacDockMenuContent: Equatable {
    var windows: [MacWindow] = []
    var actions: [MacDockAction]
    var note: String?
    var loading = false

    /// How long the menu waits for the Mac before treating it as a build without windows.
    static let patience: Duration = .seconds(4)
    static let updateNote = "Update Jarvis on your Mac to see its windows"
    static let accessibilityNote = "Allow Jarvis in Accessibility on your Mac to see its windows"

    static func resolve(support: MacWindowSupport, windows: MacAppWindows?, waitedOut: Bool) -> MacDockMenuContent {
        let older: [MacDockAction] = [.showAll, .hide]
        if let windows, support != .no {
            guard windows.accessibility else {
                return MacDockMenuContent(actions: [.showAll, .hide, .quit], note: accessibilityNote)
            }
            let actions: [MacDockAction] = (windows.canNewWindow ? [.newWindow] : []) + [.showAll, .hide, .quit]
            return MacDockMenuContent(windows: windows.windows, actions: actions)
        }
        if support == .no || waitedOut { return MacDockMenuContent(actions: older, note: updateNote) }
        return MacDockMenuContent(actions: older, loading: true)
    }
}

// MARK: - The menu

/// The popover itself (or, in the landscape rail's app column, the column's own content).
struct MacDockMenu: View {
    let session: MacScreenSession
    let app: MacApp
    /// Shown inline (the rail's column): a back row to the app icons.
    var back: (() -> Void)?
    /// Closes the menu. True when the Mac now shows what he picked (a sheet may step aside).
    let done: (_ showsMac: Bool) -> Void
    @State private var waitedOut = false
    @State private var confirmQuit = false

    private var content: MacDockMenuContent {
        .resolve(support: session.windowSupport, windows: session.windows[app.pid], waitedOut: waitedOut)
    }

    var body: some View {
        let content = content
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            if content.loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking your Mac for its windows…").font(.footnote).foregroundStyle(JcTheme.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            if !content.windows.isEmpty {
                ForEach(content.windows) { window in windowRow(window) }
                separator
            } else if !content.loading && content.note == nil {
                Text("No open windows on this Space")
                    .font(.footnote).foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                separator
            }
            if let note = content.note {
                Label { Text(note) } icon: { Image(systemName: "info.circle") }
                    .font(.footnote)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                separator
            } else if content.loading {
                separator
            }
            ForEach(content.actions) { action in
                if action == .quit && confirmQuit { quitConfirm } else { actionRow(action) }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 290, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: content)
        .animation(.easeOut(duration: 0.15), value: confirmQuit)
        .task(id: app.pid) {
            waitedOut = false
            session.requestWindows(app.pid)
            try? await Task.sleep(for: MacDockMenuContent.patience)
            if !Task.isCancelled { waitedOut = true }
        }
    }

    private var separator: some View {
        Rectangle().fill(JcTheme.border).frame(height: 1).padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(JcTheme.text)
                .accessibilityLabel("Back to apps")
            }
            MacAppIcon(app: app, image: session.appIcons[app.bundle], side: 28, showsActiveDot: false)
            Text(app.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func windowRow(_ window: MacWindow) -> some View {
        Button {
            session.raiseWindow(pid: app.pid, id: window.id)
            done(true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 16)
                    .opacity(window.front ? 1 : 0)
                Text(window.label)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if window.minimized {
                    Text("Minimized").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            .foregroundStyle(JcTheme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacMenuRowStyle())
        .accessibilityLabel("\(window.label)\(window.front ? ", front window" : "")\(window.minimized ? ", minimized" : "")")
        .accessibilityHint("Brings this window to the front")
    }

    private func actionRow(_ action: MacDockAction) -> some View {
        Button {
            if action == .quit { confirmQuit = true; return }
            session.dock(action, pid: app.pid)
            done(action != .hide)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
                Text(action.title).font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(action == .quit ? JcTheme.danger : JcTheme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacMenuRowStyle())
    }

    /// Quit asks first, in place: the app may lose unsaved work.
    private var quitConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quit \(app.name)?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            HStack(spacing: 8) {
                Button("Cancel") { confirmQuit = false }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true, full: true))
                Button("Quit") {
                    session.dock(.quit, pid: app.pid)
                    confirmQuit = false
                    done(false)
                }
                .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true, full: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A menu row: no chrome, a soft highlight while pressed.
private struct MacMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0))
    }
}

// MARK: - Press handling

extension View {
    /// An open-app icon: tap switches to the app; long-press (or a right-click with a pointer)
    /// opens its Dock menu. One UIKit view takes all three, so the strip still scrolls.
    func macAppIconPress(name: String, tap: @escaping () -> Void, menu: @escaping () -> Void) -> some View {
        overlay(MacIconPressCatcher(tap: tap, menu: menu))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityHint("Switches to it. Actions: windows and Dock menu.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .accessibilityAction(named: "Show windows") { menu() }
    }
}

private struct MacIconPressCatcher: UIViewRepresentable {
    let tap: () -> Void
    let menu: () -> Void

    final class Coordinator: NSObject {
        var tap: () -> Void = {}
        var menu: () -> Void = {}
        private let haptic = UIImpactFeedbackGenerator(style: .medium)

        @objc func tapped() { tap() }

        @objc func held(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            haptic.impactOccurred()
            menu()
        }

        @objc func rightClicked() { menu() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped))
        tap.require(toFail: hold)
        let right = UITapGestureRecognizer(target: c, action: #selector(Coordinator.rightClicked))
        right.buttonMaskRequired = .secondary
        right.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        [hold, tap, right].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.tap = tap
        context.coordinator.menu = menu
    }
}

import Foundation

/// The six bottom-nav tabs, in the order `nav.dart` declares them. The native
/// tabs cover the hot paths; More opens a grid of launchers for the rest.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case chat, voice, integrations, devices, coding, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:    return "Chat"
        case .voice:   return "Voice"
        case .integrations: return "Integrations"
        case .devices: return "Devices"
        case .coding:  return "Coding"
        case .more:    return "More"
        }
    }

    /// Inactive glyph.
    var symbol: String {
        switch self {
        case .chat:    return "bubble.left"
        case .voice:   return "waveform"
        case .integrations: return "puzzlepiece"
        case .devices: return "laptopcomputer.and.iphone"
        case .coding:  return "terminal"
        case .more:    return "square.grid.2x2"
        }
    }

    /// Active glyph — filled where a filled variant exists.
    var filledSymbol: String {
        switch self {
        case .chat:    return "bubble.left.fill"
        case .voice:   return "waveform"
        case .integrations: return "puzzlepiece.fill"
        case .devices: return "laptopcomputer.and.iphone"
        case .coding:  return "terminal.fill"
        case .more:    return "square.grid.2x2.fill"
        }
    }
}

/// App-wide navigation state, ported from the `ValueNotifier`s at the top of
/// `main.dart`.
///
/// Every page lives for the lifetime of the shell, so pages gate work on
/// `selectedTab` rather than on `onAppear`.
@MainActor
@Observable
final class AppRouter {
    /// The shell's router. Injected into the environment by `RootView`, so views
    /// read it with `@Environment(AppRouter.self)` and only the app entry point
    /// and the Siri/wake-word bridge touch the singleton.
    static let shared = AppRouter()

    var selectedTab: AppTab = .chat

    /// Latched request to "open Voice and start a turn", fired by the Siri App
    /// Intent and the wake word.
    ///
    /// A *latch*, not an event: on a cold launch the request arrives before any
    /// view has mounted to hear it, so it has to survive until Voice consumes it.
    private(set) var voiceLaunchRequested = false

    /// Incremented on every request. `main.dart` re-arms by writing false-then-true
    /// so its listeners fire even when a stale `true` is already sitting there;
    /// Observation only notifies on change, so this counter is what a view watches
    /// (`.onChange(of: router.voiceLaunchGeneration)`) to restart a turn.
    private(set) var voiceLaunchGeneration = 0

    init() {}

    /// Ask for Voice. Selects the tab immediately (so a cold launch is already on
    /// Voice by the time the shell renders) and latches until consumed.
    func requestVoiceLaunch() {
        voiceLaunchRequested = true
        voiceLaunchGeneration += 1
        selectedTab = .voice
    }

    /// Takes the latch. Returns whether there was a request to honour; the second
    /// call in a row is always false, so a re-render can't start two turns.
    @discardableResult
    func consumeVoiceLaunch() -> Bool {
        guard voiceLaunchRequested else { return false }
        voiceLaunchRequested = false
        return true
    }

    // MARK: Opening a screen in another tab

    /// A section of Devices, or a More screen, that another tab asked to show —
    /// a card on the Chat dashboard, say. Latched like the voice launch: the
    /// target page may not have been built yet, and takes it when it is.
    private(set) var devicesSectionRequest: DevicesSection?
    private(set) var moreDestinationRequest: MoreDestination?
    /// Bumped on every request, so asking for the screen that is already
    /// showing (after the user navigated away inside the tab) still notifies.
    private(set) var screenRequestGeneration = 0

    func openDevices(_ section: DevicesSection) {
        devicesSectionRequest = section
        screenRequestGeneration += 1
        selectedTab = .devices
    }

    func openMore(_ destination: MoreDestination) {
        moreDestinationRequest = destination
        screenRequestGeneration += 1
        selectedTab = .more
    }

    func consumeDevicesSection() -> DevicesSection? {
        defer { devicesSectionRequest = nil }
        return devicesSectionRequest
    }

    func consumeMoreDestination() -> MoreDestination? {
        defer { moreDestinationRequest = nil }
        return moreDestinationRequest
    }
}

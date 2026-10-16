import AppKit
import SwiftUI

/// The dylib's whole public surface — what the Python tray can reach.
///
/// The tray is a PyObjC process that already owns the menubar item and its
/// `NSPopover`. It `ctypes.CDLL`s this dylib, which registers this class with
/// the Obj-C runtime, then:
///
/// ```python
/// panel = objc.lookUpClass("JarvisVoicePanel")
/// controller = panel.makeViewControllerWithBaseURL_("http://127.0.0.1:54321")
/// popover.setContentViewController_(controller)
/// ```
///
/// `baseURL` is the loopback `PinnedProxy` the client already runs — it holds
/// the pinned certificate and the session cookie, so nothing secret crosses this
/// boundary and the Swift side has no credential code at all.
@objc(JarvisVoicePanel)
public final class JarvisVoicePanel: NSObject {

    /// Build the panel's view controller, pointed at `baseURL`.
    ///
    /// Returns nil for a `baseURL` that is not a URL — the caller then keeps
    /// whatever it was showing rather than putting an empty popover on screen.
    ///
    /// Safe to call more than once: the credentials are process-wide (the proxy
    /// port can change across a re-pair) and every controller drives the one
    /// `VoiceStore.shared`, because the mic, the audio devices and the socket
    /// are process-wide too — a second store would fight the first. So the
    /// popover and the pop-out window show one conversation, not two.
    /// The name the panel posts on when its corner button is pressed. The tray
    /// observes it and opens the standalone window; nothing has to pass a
    /// callback across the PyObjC bridge.
    @objc(openWindowNotificationName)
    public static var openWindowNotificationName: String { "JarvisVoicePanelOpenWindow" }

    @objc(makeViewControllerWithBaseURL:showsOpenInWindow:)
    @MainActor
    public static func makeViewController(baseURL: String,
                                          showsOpenInWindow: Bool) -> NSViewController? {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        ProxyCredentials.configure(baseURL: url)
        // Default `sizingOptions` (`.preferredContentSize`) on purpose: the
        // hosting controller then reports the panel's ideal size, which is what
        // an `NSPopover` falls back to when the caller sets no `contentSize` of
        // its own. Clearing the options instead leaves the hosted view at zero
        // bounds — it renders nothing at all.
        return NSHostingController(
            rootView: MacVoicePanel(showsOpenInWindow: showsOpenInWindow))
    }

    /// The panel for Jarvis.app's notch island: one wide stage — mode and chat
    /// on its left edge, settings on its right, the orb in the middle — sized
    /// by the island.
    @objc(makeIslandViewControllerWithBaseURL:)
    @MainActor
    public static func makeIslandViewController(baseURL: String) -> NSViewController? {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        ProxyCredentials.configure(baseURL: url)
        return NSHostingController(rootView: MacVoicePanel(showsOpenInWindow: false, island: true))
    }

    /// Hide (or show) the island stage's orb: Jarvis.app flies the notch's
    /// orb in and hands off to it (`MacIslandOrbLink`). An `NSNumber` so the
    /// app can call it with `perform(_:with:)`.
    @objc(setIslandOrbHidden:)
    @MainActor
    public static func setIslandOrbHidden(_ hidden: NSNumber) {
        MacIslandOrbLink.shared.hidden = hidden.boolValue
    }

    /// Posted with `userInfo["frame"]` (an `NSValue` rect in SwiftUI's global
    /// space — the hosting window's) whenever the island stage's orb lays out.
    @objc(islandOrbFrameNotificationName)
    public static var islandOrbFrameNotificationName: String { MacIslandOrbLink.frameNotificationName }

    /// Whether the orb's shader library was found beside the dylib.
    ///
    /// Worth surfacing because the failure is otherwise invisible: SwiftUI has
    /// no error channel for a missing shader function, so a dylib shipped
    /// without its bundle draws an empty rectangle where the orb should be and
    /// says nothing. The tray logs this once when it builds the panel, which
    /// turns "the orb is gone" into "run mac_app/build.sh".
    @objc(orbShaderAvailable)
    public static var orbShaderAvailable: Bool { macVoiceResourceBundle != nil }

    /// The store's diagnostics ring — the same lines the phone shows when you
    /// long-press its orb.
    ///
    /// The Mac panel has no gesture for them, and voice failures here are the
    /// kind that look like nothing happening ("still listening"), so the tray
    /// can pull them into the client log instead.
    @objc(diagnostics)
    @MainActor
    public static func diagnostics() -> [String] {
        VoiceStore.shared.diagnostics
    }

    /// Ask something by TEXT: a full turn through the same socket, model fields,
    /// tools and speech as a spoken one, with the words standing in for the
    /// transcript.
    ///
    /// The typed counterpart to the mic, for anywhere the tray wants to hand the
    /// panel a question — and the way to drive the panel end to end without a
    /// microphone, whose voice processing (rightly) cancels anything played
    /// through this Mac's own speakers.
    @objc(sendText:)
    @MainActor
    public static func sendText(_ text: String) {
        VoiceStore.shared.startWatchTurn(text: text)
    }

    /// Hold-to-talk (Jarvis.app's Talk to Jarvis shortcut, set to Hold): the
    /// key went down — start listening. A conversation already going (listening
    /// or answering) is left as it is.
    @objc(holdToTalkBegan)
    @MainActor
    public static func holdToTalkBegan() {
        let store = VoiceStore.shared
        guard !store.isActive else { return }
        Task { @MainActor in
            guard await store.ensureMic() else { return }
            await store.primaryAction()
        }
    }

    /// The key came up: what was said is sent. Let go before the mic was up
    /// (it takes a moment to connect), it's sent as soon as it is listening.
    @objc(holdToTalkEnded)
    @MainActor
    public static func holdToTalkEnded() {
        let store = VoiceStore.shared
        if store.state == .listening { store.finishSpeaking(); return }
        Task { @MainActor in
            for tick in 0..<40 {                       // up to 4 s
                try? await Task.sleep(for: .milliseconds(100))
                if store.state == .listening { store.finishSpeaking(); return }
                if tick > 15 && !store.isActive { return }   // it never started
            }
        }
    }

    /// Open Jarvis Settings — the tray's "Settings…" menu item. The proxy is the
    /// one the panel was built with, so the server's own sections load signed in.
    @objc(showSettings)
    @MainActor
    public static func showSettings() {
        MacSettingsWindow.show()
    }

    /// Stop whatever is running and release the mic — for the tray's Quit, and
    /// for a re-pair that invalidates the proxy behind us.
    ///
    /// Asynchronous on the Swift side; this returns as soon as the teardown is
    /// scheduled, so it is safe to call from the tray's own shutdown path.
    @objc(stopEverything)
    @MainActor
    public static func stopEverything() {
        Task { await VoiceStore.shared.stopAll() }
    }
}

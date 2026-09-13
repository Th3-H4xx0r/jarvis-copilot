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
    @objc(makeViewControllerWithBaseURL:)
    @MainActor
    public static func makeViewController(baseURL: String) -> NSViewController? {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        ProxyCredentials.configure(baseURL: url)
        // Default `sizingOptions` (`.preferredContentSize`) on purpose: the
        // hosting controller then reports the panel's ideal size, which is what
        // an `NSPopover` falls back to when the caller sets no `contentSize` of
        // its own. Clearing the options instead leaves the hosted view at zero
        // bounds — it renders nothing at all.
        return NSHostingController(rootView: MacVoicePanel())
    }

    /// Whether the orb's shader library was found beside the dylib.
    ///
    /// Worth surfacing because the failure is otherwise invisible: SwiftUI has
    /// no error channel for a missing shader function, so a dylib shipped
    /// without its bundle draws an empty rectangle where the orb should be and
    /// says nothing. The tray logs this once when it builds the panel, which
    /// turns "the orb is gone" into "run mac_app/build.sh".
    @objc(orbShaderAvailable)
    public static var orbShaderAvailable: Bool { macVoiceResourceBundle != nil }

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

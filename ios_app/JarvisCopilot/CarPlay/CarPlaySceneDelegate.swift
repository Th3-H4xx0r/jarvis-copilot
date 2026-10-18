import CarPlay
import UIKit

/// Jarvis on the car's screen: a second scene of this app (Info.plist
/// `CPTemplateApplicationSceneSessionRoleApplication`), built only from Apple's
/// CarPlay templates. Jarvis is a voice-based conversational CarPlay app
/// (iOS 26.4+), the one category besides navigation allowed to record.
@available(iOS 26.4, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?
    /// A URL the scene was opened with (the JARVIS Voice widget), handled once the screen is up.
    private var pendingURL: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        pendingURL = connectionOptions.urlContexts.first?.url
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        AppServices.shared.setCarPlayActive(true)
        CarPresence.shared.setCarPlay(true)
        CarScreen.scene = templateApplicationScene   // car_directions opens Maps here
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coordinator
        coordinator.start()
        // Voice first: opening Jarvis on the car starts a conversation (Apple's rule
        // for voice-based conversational apps). Done or Stop leaves the tabs.
        coordinator.handle(.startVoice)
        if let url = pendingURL {
            pendingURL = nil
            open(url)
        }
    }

    /// Back to Jarvis from another car app (its icon, or the widget): voice again.
    func sceneWillEnterForeground(_ scene: UIScene) {
        coordinator?.voice.attach()
        coordinator?.handle(.startVoice)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        coordinator?.stop()
        coordinator = nil
        CarScreen.scene = nil
        AppServices.shared.setCarPlayActive(false)
        CarPresence.shared.setCarPlay(false)
    }

    /// The car switched to another app (Maps, Music): the conversation ends here.
    func sceneDidEnterBackground(_ scene: UIScene) {
        coordinator?.voice.stop()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { open(context.url) }
    }

    /// The widgets' `jarviscopilot://voice` starts talking on the car — the Talk
    /// widget's orb for one answer; anything else goes through the phone's usual router.
    private func open(_ url: URL) {
        if CarPlayLinks.isVoice(url) {
            coordinator?.handle(CarPlayLinks.wantsOneAnswer(url) ? .talkOnce : .startVoice)
        } else {
            AppServices.shared.open(url: url)
        }
    }
}

/// The deep links the car's scene answers itself.
enum CarPlayLinks {
    static func isVoice(_ url: URL) -> Bool {
        url.scheme == "jarviscopilot" && (url.host == "voice" || url.path == "/voice")
    }

    /// `?once=1`: the Talk widget's orb — one answer, then the mic goes off.
    static func wantsOneAnswer(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "once" && $0.value == "1" } ?? false
    }
}

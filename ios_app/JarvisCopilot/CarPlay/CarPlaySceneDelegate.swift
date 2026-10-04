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
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController)
        self.coordinator = coordinator
        coordinator.start()
        if let url = pendingURL {
            pendingURL = nil
            open(url)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        coordinator?.stop()
        coordinator = nil
        AppServices.shared.setCarPlayActive(false)
    }

    /// The car switched to another app (Maps, Music): CarPlay allows recording only
    /// while Jarvis's voice screen shows, so the conversation ends here.
    func sceneDidEnterBackground(_ scene: UIScene) {
        coordinator?.voice.stop()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { open(context.url) }
    }

    /// The widget's `jarviscopilot://voice` starts talking on the car; anything
    /// else goes through the phone's usual router.
    private func open(_ url: URL) {
        if CarPlayLinks.isVoice(url) {
            coordinator?.handle(.startVoice)
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
}

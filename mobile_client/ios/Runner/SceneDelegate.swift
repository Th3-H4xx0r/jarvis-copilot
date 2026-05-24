import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)

        // FlutterSceneDelegate constructs the FlutterViewController in
        // super; defer one runloop turn so window/rootViewController are
        // populated before we look them up.
        let urls = connectionOptions.urlContexts.map { $0.url }
        DispatchQueue.main.async { [weak self] in
            self?.wireBridges(scene: scene, pendingURLs: urls)
        }
    }

    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        super.scene(scene, openURLContexts: URLContexts)
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        for ctx in URLContexts {
            app.handlePairDeepLink(ctx.url)
        }
    }

    private func wireBridges(scene: UIScene, pendingURLs: [URL]) {
        guard let windowScene = scene as? UIWindowScene,
              let window = windowScene.windows.first,
              let controller = window.rootViewController as? FlutterViewController else {
            return
        }
        // Shortcuts channel is owned by AppDelegate (it also routes the
        // x-callback-url results back to Dart), wired in attachFlutterController.
        HealthKitBridge.register(with: controller)
        TorchBridge.register(with: controller)
        AppOpenBridge.register(with: controller)
        SmsComposeBridge.register(with: controller)

        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.attachFlutterController(controller)
            for url in pendingURLs {
                app.handlePairDeepLink(url)
            }
        }
    }
}

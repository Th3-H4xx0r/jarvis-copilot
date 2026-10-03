import CarPlay
import UIKit

/// Jarvis on the car's screen: a second scene of this app (Info.plist
/// `CPTemplateApplicationSceneSessionRoleApplication`), built only from Apple's
/// CarPlay templates. CarPlay apps are voice-based conversational apps here
/// (iOS 26.4+), which is the one category besides navigation allowed to record.
@available(iOS 26.4, *)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let tabs = ["Jarvis", "Chats", "Devices"].map { title in
            CPListTemplate(title: title, sections: [CPListSection(items: [CPListItem(text: title, detailText: nil)])])
        }
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: tabs), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }
}

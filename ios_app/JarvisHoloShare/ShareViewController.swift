import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Jarvis" in the share sheet → Holo Drop: the Orbit with your devices around what you're
/// sharing; fling it toward one or tap one. Uses the paired server's credentials from the
/// team Keychain group (VaultShareKeychain), like the vault share.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let root = HoloShareRoot(context: extensionContext)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .black
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}


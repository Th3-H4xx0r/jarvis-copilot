import Flutter
import UIKit

/// MethodChannel wiring for the `run_shortcut` + `shortcuts_list`
/// skills. `run` opens the Shortcuts URL scheme; `list` is a best
/// effort — iOS doesn't expose an API for enumerating user shortcuts,
/// so we return an empty list and let the agent ask the user.
class ShortcutsBridge {
    static func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "jarviscopilot/shortcuts",
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "list":
                result([])
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

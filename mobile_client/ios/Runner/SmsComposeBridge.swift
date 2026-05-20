import Flutter
import MessageUI
import UIKit

/// MethodChannel for the iOS `send_sms` skill.
///
/// iOS has no programmatic SMS API — apps that ship to the store must
/// route through MFMessageComposeViewController and let the user tap
/// Send. We pre-fill recipient + body and present the sheet from the
/// top-most view controller.
///
/// We hold one delegate at a time (composer is modal, so one is enough).
class SmsComposeBridge: NSObject, MFMessageComposeViewControllerDelegate {
    private static let shared = SmsComposeBridge()
    private var pendingResult: FlutterResult?

    static func register(with controller: FlutterViewController) {
        let ch = FlutterMethodChannel(
            name: "jarviscopilot/sms",
            binaryMessenger: controller.binaryMessenger
        )
        ch.setMethodCallHandler { (call, result) in
            switch call.method {
            case "compose":
                guard let args = call.arguments as? [String: Any],
                      let number = (args["number"] as? String).map({ $0.trimmingCharacters(in: .whitespaces) }),
                      let message = args["message"] as? String,
                      !number.isEmpty else {
                    result(FlutterError(code: "bad_args",
                                        message: "number + message required",
                                        details: nil))
                    return
                }
                shared.present(number: number, message: message, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func present(number: String, message: String, result: @escaping FlutterResult) {
        guard MFMessageComposeViewController.canSendText() else {
            result(["shown": false, "error": "SMS not available on this device"])
            return
        }
        // Capture the pending result; we report back when the user
        // dismisses the sheet (sent / cancelled / failed).
        if pendingResult != nil {
            result(["shown": false, "error": "another compose is already in progress"])
            return
        }
        pendingResult = result

        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = [number]
        composer.body = message

        DispatchQueue.main.async {
            guard let top = SmsComposeBridge.topViewController() else {
                self.complete(result: ["shown": false, "error": "no top view controller"])
                return
            }
            top.present(composer, animated: true, completion: nil)
        }
    }

    func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        controller.dismiss(animated: true, completion: nil)
        let payload: [String: Any]
        switch result {
        case .sent:      payload = ["shown": true, "sent": true]
        case .cancelled: payload = ["shown": true, "sent": false, "cancelled": true]
        case .failed:    payload = ["shown": true, "sent": false, "error": "send failed"]
        @unknown default: payload = ["shown": true, "sent": false, "error": "unknown result"]
        }
        complete(result: payload)
    }

    private func complete(result payload: [String: Any]) {
        let r = pendingResult
        pendingResult = nil
        r?(payload)
    }

    /// Walk the responder chain to find the visible view controller.
    /// Required because the FlutterViewController may not be the top
    /// presenter if another sheet is already up.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let window = active?.windows.first(where: { $0.isKeyWindow }) ?? active?.windows.first,
              var top = window.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

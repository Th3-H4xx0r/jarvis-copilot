import AVFoundation
import Flutter
import UIKit

/// MethodChannel for the `flashlight_on` / `flashlight_off` skills.
/// Backs `jarviscopilot/torch`.
///
/// Uses the default video capture device's torch mode. If the device
/// has no torch (iPad without flash, simulator), we surface a clean
/// error so the Dart layer reports `{on: false, error: …}`.
class TorchBridge {
    static func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "jarviscopilot/torch",
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "on":  setTorch(on: true, result: result)
            case "off": setTorch(on: false, result: result)
            default:    result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func setTorch(on: Bool, result: @escaping FlutterResult) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            result(FlutterError(code: "no_torch", message: "device has no torch", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            // Mode is the documented switch; setTorchModeOn(level:) lets us
            // tune brightness but we don't bother with that here.
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            result(on)
        } catch {
            result(FlutterError(
                code: "torch_failed",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }
}

import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MessageUI)
import MessageUI
#endif

/// Production implementations of the UIKit-shaped boundaries.
///
/// Each one hops to the main actor internally so the skills above can stay
/// `Sendable`-clean and the tests can drive plain mocks.

// MARK: - Clipboard

final class DefaultClipboard: Clipboarding {
    func read() async -> String? {
        #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string }
        #else
        nil
        #endif
    }

    func write(_ text: String) async {
        #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string = text }
        #endif
    }
}

// MARK: - Opening URLs

final class DefaultURLOpener: URLOpening {
    func canOpen(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.canOpenURL(url) }
        #else
        false
        #endif
    }

    func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }
}

// MARK: - Device info

final class DefaultDeviceInfo: DeviceInfoProviding {
    func info() async -> [String: String] {
        #if canImport(UIKit)
        let device = await MainActor.run { (name: UIDevice.current.name,
                                            system: UIDevice.current.systemName,
                                            version: UIDevice.current.systemVersion) }
        return [
            "platform": "ios",
            "model": Self.machine(),
            "name": device.name,
            "system": device.system,
            "system_version": device.version,
            "locale": Locale.current.identifier,
        ]
        #else
        return ["platform": "unknown", "locale": Locale.current.identifier]
        #endif
    }

    /// `utsname.machine` ("iPhone16,2") — what the Flutter client reported as
    /// `model`, and more useful to the agent than UIDevice's "iPhone".
    private static func machine() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
}

// MARK: - Battery

final class DefaultBattery: BatteryReading {
    func snapshot() async -> BatterySnapshot {
        #if canImport(UIKit)
        return await MainActor.run {
            // Monitoring has to be armed before the values mean anything; the
            // simulator still reports -1 / .unknown.
            UIDevice.current.isBatteryMonitoringEnabled = true
            let raw = UIDevice.current.batteryLevel
            let level = raw < 0 ? -1 : Int((raw * 100).rounded())
            let state: String
            switch UIDevice.current.batteryState {
            case .charging:    state = "charging"
            case .full:        state = "full"
            case .unplugged:   state = "discharging"
            default:           state = "unknown"
            }
            return BatterySnapshot(level: level, state: state)
        }
        #else
        return BatterySnapshot(level: -1, state: "unknown")
        #endif
    }
}

// MARK: - Haptics

final class DefaultHaptics: Vibrating {
    var isAvailable: Bool {
        #if canImport(UIKit)
        // iPads and the simulator have no haptic engine; UIDevice doesn't say,
        // but the Taptic Engine only exists on iPhone.
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    func buzz() async {
        #if canImport(UIKit)
        await MainActor.run {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred()
        }
        #endif
    }
}

// MARK: - Torch

/// Adapted from `mobile_client/ios/Runner/TorchBridge.swift`. Uses the default
/// video capture device's torch mode; a device with no torch (iPad, simulator)
/// surfaces a clean error so the skill reports `{on: false, error: …}`.
final class DefaultTorch: Torching {
    func setTorch(on: Bool) async throws -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            throw SkillError.unavailable("device has no torch")
        }
        do {
            try device.lockForConfiguration()
            // Mode is the documented switch; setTorchModeOn(level:) would let us
            // tune brightness, which nothing here needs.
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            return on
        } catch {
            throw SkillError.failed(error.localizedDescription)
        }
    }
}

// MARK: - Share sheet

/// Presents `UIActivityViewController` from the top-most view controller.
///
/// The skills layer only hands over a payload; if no window is up (a background
/// wake) this reports unavailable rather than pretending to have shared.
final class DefaultSharePresenter: SharePresenting {
    func present(_ payload: SharePayload) async throws -> Bool {
        #if canImport(UIKit)
        return try await MainActor.run {
            let items: [Any]
            switch payload {
            case .text(let text, let subject):
                items = [ShareTextItem(text: text, subject: subject ?? "")]
            case .image(let data, _, let caption):
                guard let image = UIImage(data: data) else {
                    throw SkillError.badArgument("image_base64 is not a decodable image")
                }
                items = caption.map { [image, $0] as [Any] } ?? [image]
            }
            guard let top = TopViewController.find() else {
                throw SkillError.unavailable("no window to present the share sheet from")
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            // An iPad needs an anchor or the popover assertion fires.
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            top.present(sheet, animated: true)
            return true
        }
        #else
        throw SkillError.unavailable("share sheet needs UIKit")
        #endif
    }
}

#if canImport(UIKit)
/// Carries the optional `subject` (used by Mail) alongside the shared text —
/// `UIActivityViewController` only exposes it through an item source.
private final class ShareTextItem: NSObject, UIActivityItemSource {
    private let text: String
    private let subject: String

    init(text: String, subject: String) {
        self.text = text
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? { text }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String { subject }
}
#endif

// MARK: - SMS composer

#if canImport(MessageUI)
/// Adapted from `mobile_client/ios/Runner/SmsComposeBridge.swift`.
///
/// iOS has no programmatic SMS API — apps that ship to the store must route
/// through `MFMessageComposeViewController` and let the user tap Send. We
/// pre-fill recipient + body and present the sheet from the top-most view
/// controller, then report what the user did.
@MainActor
final class DefaultSmsComposer: NSObject, MFMessageComposeViewControllerDelegate, SmsComposing {
    private var pending: CheckedContinuation<SmsComposeOutcome, Never>?

    nonisolated func compose(number: String, message: String) async throws -> SmsComposeOutcome {
        try await present(number: number, message: message)
    }

    private func present(number: String, message: String) async throws -> SmsComposeOutcome {
        guard MFMessageComposeViewController.canSendText() else {
            throw SkillError.unavailable("SMS not available on this device")
        }
        // The composer is modal, so one at a time is enough — and a second
        // request while one is up would strand the first continuation.
        guard pending == nil else {
            throw SkillError.failed("another compose is already in progress")
        }
        guard let top = TopViewController.find() else {
            throw SkillError.unavailable("no window to present the composer from")
        }
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = [number]
        composer.body = message
        return await withCheckedContinuation { continuation in
            pending = continuation
            top.present(composer, animated: true)
        }
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
        let outcome: SmsComposeOutcome
        switch result {
        case .sent:      outcome = .sent
        case .cancelled: outcome = .cancelled
        case .failed:    outcome = .failed("send failed")
        @unknown default: outcome = .failed("unknown result")
        }
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }
}
#endif

// MARK: - Opening another app

/// Adapted from `mobile_client/ios/Runner/AppOpenBridge.swift`: resolve a
/// friendly app name to a URL scheme, then open it.
final class DefaultAppOpener: AppOpening {
    private let urls: any URLOpening

    init(urls: any URLOpening = DefaultURLOpener()) { self.urls = urls }

    func open(appName: String, schemeURL: String) async -> AppOpenOutcome {
        let name = appName.trimmingCharacters(in: .whitespaces).lowercased()
        let explicit = schemeURL.trimmingCharacters(in: .whitespaces)
        guard let candidate = AppSchemeTable.resolve(appName: name, schemeURL: explicit) else {
            return AppOpenOutcome(launched: false, error: "no scheme for \"\(appName)\"")
        }
        guard let url = URL(string: candidate) else {
            return AppOpenOutcome(launched: false, error: "\"\(candidate)\" is not a URL")
        }
        // canOpenURL only answers for schemes declared in
        // LSApplicationQueriesSchemes; we open regardless and report what
        // actually happened, so the caller never claims a false success.
        let launched = await urls.open(url)
        return AppOpenOutcome(launched: launched, schemeURL: url.absoluteString,
                              matched: explicit.isEmpty ? appName : explicit)
    }
}

// MARK: - Top view controller

#if canImport(UIKit)
/// Walk the scene graph for the visible view controller. Required because the
/// SwiftUI hosting controller may not be the top presenter when another sheet is
/// already up.
@MainActor
enum TopViewController {
    static func find() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let active = (scenes.first { $0.activationState == .foregroundActive }
                      ?? scenes.first) as? UIWindowScene
        guard let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
#endif

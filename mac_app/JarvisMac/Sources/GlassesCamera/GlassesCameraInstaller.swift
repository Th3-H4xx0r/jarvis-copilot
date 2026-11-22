import AppKit
import Foundation
import Observation
import SystemExtensions

/// Installs the Jarvis Glasses camera: the system extension inside Jarvis.app
/// (Contents/Library/SystemExtensions), activated with OSSystemExtensionRequest. macOS then
/// asks him once to allow it (System Settings → General → Login Items & Extensions → Camera
/// Extensions). Works only from a Developer ID-signed, notarized Jarvis in /Applications.
@MainActor
@Observable
final class GlassesCameraInstaller: NSObject {
    static let shared = GlassesCameraInstaller()

    enum State: Equatable {
        case unknown, notInstalled, working, needsApproval, installed, restartNeeded, failed(String)
    }

    private(set) var state: State = .unknown

    /// What macOS knows about the camera (installed, waiting for approval…).
    func check() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: GlassesCameraSpec.extensionBundleID,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func install() {
        state = .working
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: GlassesCameraSpec.extensionBundleID,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        state = .working
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: GlassesCameraSpec.extensionBundleID,
                                                                   queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// System Settings where camera extensions are allowed.
    static func openApprovalSettings() {
        let links = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                     "x-apple.systempreferences:com.apple.preference.security?Security"]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Why an install failed, in his words (and what to do about it).
    nonisolated static func explain(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: ns.code) else {
            return ns.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return "Jarvis must be in the Applications folder (/Applications) to install a camera. Move it there, open it from there and try again."
        case .missingEntitlement:
            return "This copy of Jarvis isn't signed for cameras yet. It needs the Developer ID build (mac_app/scripts/build-developer-id.sh)."
        case .codeSignatureInvalid, .validationFailed:
            return "macOS refused the camera's signature. It needs the Developer ID-signed, notarized build of Jarvis."
        case .extensionNotFound, .extensionMissingIdentifier:
            return "The camera isn't inside this copy of Jarvis. Rebuild it with mac_app/build-app.sh."
        case .authorizationRequired:
            return "macOS needs your OK: System Settings → General → Login Items & Extensions → Camera Extensions → Jarvis Glasses."
        case .forbiddenBySystemPolicy:
            return "This Mac's policy doesn't allow camera extensions."
        case .requestCanceled, .requestSuperseded:
            return "Cancelled."
        default:
            return ns.localizedDescription
        }
    }
}

extension GlassesCameraInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace   // a newer Jarvis brings a newer camera
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            switch result {
            case .willCompleteAfterReboot: state = .restartNeeded
            default: state = state == .working || state == .needsApproval ? .installed : state
            }
            GlassesCameraService.shared.refresh()
            check()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let text = Self.explain(error)
        MainActor.assumeIsolated { state = .failed(text) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let live = properties.filter { !$0.isUninstalling }
        MainActor.assumeIsolated {
            guard state != .working else { return }
            if live.contains(where: \.isEnabled) { state = .installed }
            else if live.contains(where: \.isAwaitingUserApproval) { state = .needsApproval }
            else if case .failed = state { return }
            else { state = .notInstalled }
        }
    }
}

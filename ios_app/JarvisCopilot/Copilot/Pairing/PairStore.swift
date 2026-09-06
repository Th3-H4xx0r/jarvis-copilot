import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The pairing boundary — everything `PairStore` needs from `BridgeClient`, and
/// nothing else, so the state machine is testable without a server or a Keychain.
@MainActor
protocol PairingClaiming: AnyObject {
    var serverURL: String { get set }
    var isPaired: Bool { get }
    /// Stores a Cloudflare Access service token. Must land *before* the claim: a
    /// tunnel-fronted server 302-redirects a claim that arrives without
    /// CF-Access headers to its SSO login.
    func applyScanned(cfClientID: String?, cfClientSecret: String?)
    func claim(code: String) async throws
}

extension BridgeClient: PairingClaiming {
    /// `pair(code:)` under the boundary's name. Add-only: it changes nothing about
    /// how `BridgeClient` pairs.
    func claim(code: String) async throws { try await pair(code: code) }
}

/// Drives the pair screen, ported from `pages/pair_page.dart`.
///
/// Three entry vectors, as in Flutter: scan the QR the webui's "+ Pair new
/// device" modal shows, type the 6-char code, or arrive from a
/// `jarviscopilot://pair?server=…&code=…` deep link (which pre-fills the form —
/// the user still confirms).
@MainActor
@Observable
final class PairStore {

    enum Phase: Equatable {
        /// The manual-entry form.
        case form
        /// The camera is up.
        case scanning
        /// A claim is in flight.
        case pairing
        /// Done — `RootView` swaps in the shell.
        case paired
    }

    private(set) var phase: Phase = .form

    var serverURL = ""
    var code = ""
    var deviceName: String
    var cfClientID = ""
    var cfClientSecret = ""

    var errorMessage: String?

    /// Whether the collapsed "behind a Cloudflare tunnel?" section is open. A scan
    /// that carried a token opens it — otherwise the values sit hidden and look
    /// like they were never copied.
    var showsCloudflareFields = false

    /// Non-nil when the camera itself failed, so the page can say why rather than
    /// showing a black rectangle.
    var scannerMessage: String?

    private let pairing: PairingClaiming
    private let scanner: QRScanning
    private let preferences: KeyValueStore
    private let onServerChanged: () -> Void

    /// `scanner` is optional rather than defaulted to a `CameraQRScanner()`: a
    /// default argument expression is evaluated in the caller's (nonisolated)
    /// context, and the camera is main-actor-isolated.
    ///
    /// `onServerChanged` fires once the phone is talking to a DIFFERENT server;
    /// production forgets `ChatAPI`'s process-wide feature probe. Injectable so
    /// the call can be asserted without reaching into that global.
    init(pairing: PairingClaiming = BridgeClient.shared,
         scanner: QRScanning? = nil,
         preferences: KeyValueStore = UserDefaults.standard,
         onServerChanged: (() -> Void)? = nil) {
        self.pairing = pairing
        self.scanner = scanner ?? CameraQRScanner()
        self.preferences = preferences
        self.onServerChanged = onServerChanged ?? { ChatAPI.resetFeatureDetection() }
        self.deviceName = preferences.string(SettingsStore.Keys.deviceName)
            ?? SettingsStore.defaultDeviceName
    }

    /// The camera, for the preview view to display. `nil` in tests.
    var cameraScanner: CameraQRScanner? { scanner as? CameraQRScanner }

    var canSubmit: Bool {
        !jcTrim(serverURL).isEmpty && !jcTrim(code).isEmpty
    }

    // MARK: Scanning

    func startScanning() {
        errorMessage = nil
        scannerMessage = nil
        phase = .scanning
        scanner.start { [weak self] raw in
            self?.handleScan(raw)
        }
        // The camera reports a failure while starting (no device, session refused
        // the output), so read it back rather than showing a black rectangle.
        scannerMessage = cameraScanner?.failureMessage
    }

    func cancelScanning() {
        scanner.stop()
        phase = .form
    }

    /// Feeds one decoded barcode. Returns whether it was recognised.
    ///
    /// Unrecognised codes deliberately leave the camera running — the user may be
    /// pointing at a sticker next to the one they want.
    @discardableResult
    func handleScan(_ raw: String) -> Bool {
        guard let payload = PairingPayload(raw: raw) else {
            errorMessage = "Unrecognised QR. Expected a Jarvis Copilot pair link or server URL."
            return false
        }

        // Only fill what the payload actually carries, so a partial QR can't wipe
        // a field the user already typed.
        if let server = payload.server, !server.isEmpty { serverURL = server }
        if let code = payload.code, !code.isEmpty { self.code = code }
        if let id = payload.cfClientID, !id.isEmpty {
            cfClientID = id
            showsCloudflareFields = true
        }
        if let secret = payload.cfClientSecret, !secret.isEmpty {
            cfClientSecret = secret
            showsCloudflareFields = true
        }
        errorMessage = nil
        cancelScanning()
        return true
    }

    // MARK: Claiming

    func submit() async {
        let server = jcTrim(serverURL)
        let claimCode = jcTrim(code).uppercased()

        guard !server.isEmpty, !claimCode.isEmpty else {
            errorMessage = "Server URL and code are required"
            return
        }
        // The session cookie is the whole credential. A bare host is fine —
        // `BridgeClient` assumes https for one — but an explicit `http://` would
        // put the cookie on the wire in the clear.
        if server.contains("://"), !server.lowercased().hasPrefix("https://") {
            errorMessage = "Server URL must be https://"
            return
        }

        phase = .pairing
        errorMessage = nil

        pairing.serverURL = server
        // Both halves or neither: a lone client id makes the edge reject the claim
        // with a less useful error than sending nothing at all.
        let id = jcTrim(cfClientID), secret = jcTrim(cfClientSecret)
        if !id.isEmpty, !secret.isEmpty {
            pairing.applyScanned(cfClientID: id, cfClientSecret: secret)
        }

        do {
            try await pairing.claim(code: claimCode)
            // `ChatAPI`'s streaming-start probe is process-wide and this is a
            // new server: keeping the old verdict makes every turn on a server
            // of the other vintage take the wrong path for the whole launch.
            onServerChanged()
            let name = jcTrim(deviceName)
            preferences.set(name.isEmpty ? nil : name, forKey: SettingsStore.Keys.deviceName)
            code = ""
            phase = .paired
        } catch {
            errorMessage = "Pair failed: \(apiErrorMessage(error))"
            phase = .form
        }
    }
}

/// Local trim helper. Deliberately a free function rather than a `String`
/// extension — several areas are being ported in parallel and a shared
/// `String.trimmed` would collide.
func jcTrim(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

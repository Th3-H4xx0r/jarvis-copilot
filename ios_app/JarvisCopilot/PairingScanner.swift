import SwiftUI
import AVFoundation

/// What a JarvisCopilot pairing QR can carry.
///
/// The accepted forms mirror the Flutter client's `pair_page.dart` exactly, so the same
/// QR works for both apps:
///  1. `jarviscopilot://pair?server=…&code=…[&lan_url=…&cf_id=…&cf_secret=…]`
///  2. `https://host[:port]/pair` → server is the scheme + authority, path dropped
///  3. a bare `https://host[:port]` → used directly as the server URL
///
/// **https only.** The session cookie the claim returns IS the credential, and
/// the Cloudflare service token a QR can carry is a bearer secret; over plain
/// http both go out in the clear to whoever is on the path — and a QR is exactly
/// the vector where the user can't read the URL they're agreeing to. A payload
/// naming an `http://` server is refused here rather than downstream, so no
/// caller can accidentally accept one.
struct PairingPayload: Equatable {
    var server: String?
    /// An on-LAN shortcut the webui may add to the QR alongside the public URL.
    /// No QR the Flutter client produces today carries one, so it stays optional
    /// and nothing depends on it.
    var lanURL: String?
    var code: String?
    var cfClientID: String?
    var cfClientSecret: String?

    /// Returns nil for anything that isn't a recognised pair link or server URL, so the
    /// caller can keep the camera open rather than dismissing on a stray barcode.
    init?(raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let uri = URLComponents(string: text) else { return nil }

        if uri.scheme == "jarviscopilot", uri.host == "pair" {
            let q = Dictionary(uniqueKeysWithValues:
                (uri.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            server = q["server"]
            lanURL = q["lan_url"]
            code = q["code"]
            cfClientID = q["cf_id"]
            cfClientSecret = q["cf_secret"]
            if Self.isPlainHTTP(server) || Self.isPlainHTTP(lanURL) { return nil }
        } else if uri.scheme == "https" {
            guard let host = uri.host else { return nil }
            let port = uri.port.map { ":\($0)" } ?? ""
            server = "https://\(host)\(port)"
        } else {
            return nil
        }

        if server?.isEmpty ?? true, code?.isEmpty ?? true { return nil }
    }

    private static func isPlainHTTP(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }
}

#if canImport(UIKit)

/// Full-screen QR scanner. AVFoundation directly — no third-party dependency, matching
/// the rest of the app.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called for each decoded payload. Return true to stop scanning.
    let onScan: (PairingPayload) -> Bool
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((PairingPayload) -> Bool)?
        var onFailure: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var handled = false
        /// Serial, for the same reason as `Copilot/Pairing/QRScanner.swift`: a
        /// detached start and a main-thread stop have no order between them, so
        /// the camera could stay on after the sheet closed.
        private let sessionQueue = DispatchQueue(label: "com.jarviscopilot.jarviscopilotMobileAndIOS.pair-scanner")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onFailure?("No camera available")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onFailure?("Could not start the camera")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            let session = session
            sessionQueue.async { if !session.isRunning { session.startRunning() } }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            stopSession()
        }

        private func stopSession() {
            let session = session
            sessionQueue.async { if session.isRunning { session.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let raw = object.stringValue else { return }
            guard let payload = PairingPayload(raw: raw) else {
                // Unrecognised — keep scanning so a different code can be tried.
                onFailure?("Unrecognised QR. Expected a Jarvis Copilot pair link or an "
                         + "https:// server URL.")
                return
            }
            if onScan?(payload) == true {
                handled = true
                stopSession()
            }
        }
    }
}

/// Sheet wrapper: camera permission, the scanner, and a way out.
struct PairingScannerSheet: View {
    let onScan: (PairingPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    ContentUnavailableView(
                        "Camera access needed",
                        systemImage: "camera.fill",
                        description: Text("Allow camera access in Settings, or type the "
                                        + "pairing code instead."))
                } else {
                    QRScannerView(
                        onScan: { payload in
                            onScan(payload)
                            dismiss()
                            return true
                        },
                        onFailure: { message = $0 })
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text(message ?? "Point the camera at the pairing QR code")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(
                                cornerRadius: 14, style: .continuous))
                            .padding(24)
                    }
                }
            }
            .navigationTitle("Scan to pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Cancel") { dismiss() }
            }
            .task {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                denied = AVCaptureDevice.authorizationStatus(for: .video) != .authorized
            }
        }
    }
}

#endif

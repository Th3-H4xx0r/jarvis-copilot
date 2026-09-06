import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The camera boundary `PairStore` talks to. Behind a protocol so the pairing
/// state machine can be driven from a test without a camera, a permission prompt
/// or a run loop.
///
/// Implementations own the capture session; the view only displays their preview.
@MainActor
protocol QRScanning: AnyObject {
    /// Start delivering decoded strings. Calling it again replaces the sink.
    func start(onCode: @escaping (String) -> Void)
    /// Stop the camera. Safe to call when it was never started.
    func stop()
}

#if os(iOS)

/// `AVCaptureMetadataOutput` behind `QRScanning`. No third-party scanner — the
/// rest of the app is system-frameworks-only.
///
/// The session lives here rather than in the SwiftUI view so it survives a
/// re-render, and so the store (not the view) decides when the camera runs.
@MainActor
final class CameraQRScanner: NSObject, QRScanning, AVCaptureMetadataOutputObjectsDelegate {
    /// Set when the camera could not be brought up — the page shows it instead of
    /// a black rectangle.
    private(set) var failureMessage: String?

    private let session = AVCaptureSession()
    private var onCode: ((String) -> Void)?
    private var configured = false

    /// `startRunning`/`stopRunning` block for a beat and must not run on the
    /// main actor. They used to go to `Task.detached`, which gives NO ordering:
    /// a start dispatched before a stop could finish after it, leaving the
    /// camera (and its indicator) on after the sheet was dismissed. One serial
    /// queue makes the last call win.
    private let sessionQueue = DispatchQueue(label: "com.jarviscopilot.jarviscopilotMobileAndIOS.qr-session")

    /// The layer `QRPreview` puts on screen.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    func start(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        guard configure() else { return }
        let session = session
        // `isRunning` is read on the queue, not here: checking it from the main
        // actor races the queue's own start/stop.
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        onCode = nil
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configure() -> Bool {
        if configured { return failureMessage == nil }
        configured = true

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            failureMessage = "No camera available. Type the pairing code instead."
            return false
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            failureMessage = "Could not start the camera. Type the pairing code instead."
            return false
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set AFTER adding the output — the available types are empty until then.
        output.metadataObjectTypes = [.qr]
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let raw = object.stringValue else { return }
        // The camera streams detections continuously; the store decides whether a
        // payload is worth acting on and stops us when it is.
        onCode?(raw)
    }
}

/// Puts a `CameraQRScanner`'s preview on screen. Deliberately dumb: it starts and
/// stops nothing, so the camera's lifetime is the store's business.
struct QRPreview: UIViewRepresentable {
    let scanner: CameraQRScanner

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.layer.addSublayer(scanner.previewLayer)
        view.previewLayer = scanner.previewLayer
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}

#else

/// No camera off iOS — the manual code entry is the whole flow there.
@MainActor
final class CameraQRScanner: QRScanning {
    private(set) var failureMessage: String? = "This device has no camera."
    func start(onCode: @escaping (String) -> Void) {}
    func stop() {}
}

#endif

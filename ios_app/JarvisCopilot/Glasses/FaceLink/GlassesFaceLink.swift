import Foundation
import Observation

/// Serves the glasses' Face Link app from Jarvis. It answers "ready" so the glasses go past the
/// permission screen the official iPhone app leaves them on; the glasses then detect faces
/// themselves and send a small square face crop (AR_IDENTIFY JPEG) while a face is in the cross.
/// Each crop goes into the Face library, and the lens gets a placeholder "Unknown person" card —
/// there's no recognition yet.
@MainActor
@Observable
final class GlassesFaceLink {
    static let shared = GlassesFaceLink()

    /// Face crops received since launch.
    private(set) var imagesReceived = 0

    private var observer: UUID?
    private var sendChain: Task<Void, Never>?
    private var lastCard = Date.distantPast

    func install() {
        guard observer == nil else { return }
        observer = InmoSession.shared.addEventObserver { [weak self] in self?.receive($0) }
    }

    private func receive(_ event: InmoEvent) {
        guard case .message(let type, let fields, _) = event, [1, 15, 28].contains(type) else { return }
        let parsed: GlassesFaceLinkWire.Event?
        do { parsed = try GlassesFaceLinkWire.parse(type: type, fields: fields) } catch {
            InmoRuntimeDiagnostics.note("face link message unreadable type=\(type): \(error)")
            return
        }
        guard let parsed else { return }
        switch parsed {
        case .opened:
            InmoRuntimeDiagnostics.note("face link opened on the lens")
        case .closed:
            InmoRuntimeDiagnostics.note("face link closed; images this run=\(imagesReceived)")
        case .prepareRequested:
            // Holding GO as the Live captions gesture opens Face Link for a moment;
            // it's being closed again, so its camera never starts.
            if LiveLensBridge.shared.gestureOpened(module: GlassesFaceLinkWire.module) { return }
            post(GlassesFaceLinkWire.prepared(true))
        case .image(let image):
            // Only Face Link's face crops (ImageModelType AR_IDENTIFY = 0). Snapshots (2) and lens
            // screenshots ride the same IMAGE message and aren't faces.
            guard image.kind == GlassesFaceLinkWire.faceImageType else { return }
            imagesReceived += 1
            if imagesReceived == 1 || imagesReceived % 10 == 0 {
                InmoRuntimeDiagnostics.note("face link face #\(imagesReceived) \(image.data.count) bytes")
            }
            post(GlassesFaceLinkWire.imageReceived(timestamp: image.timestamp))
            let face = GlassesFaceLibrary.shared.add(image.data)
            // Placeholder answer to "who is this?" — no recognition yet. One card at a time:
            // the glasses send a crop every moment a face is in the cross and the lens needs a beat.
            if Date().timeIntervalSince(lastCard) >= 1.5 {
                lastCard = Date()
                post(GlassesFaceLinkWire.identified(name: "Unknown person",
                                                    job: face == nil ? "Face seen" : "Saved to face library",
                                                    company: "Face #\(GlassesFaceLibrary.shared.faces.count)",
                                                    similarity: 0.5))
            }
        }
    }

    private func post(_ message: Data) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            do { try await InmoSession.shared.send(message) } catch {
                InmoRuntimeDiagnostics.note("face link send failed: \(error.localizedDescription)")
            }
        }
    }
}

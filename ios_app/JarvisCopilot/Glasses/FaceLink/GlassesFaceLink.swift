import Foundation
import Observation

/// Serves the glasses' Face Link app from Jarvis. PROBE STAGE: it answers
/// "ready" so the glasses go past the permission screen the official iPhone app
/// leaves them on, keeps the images they send (Application Support/FaceLinkProbe)
/// and answers each with a test card showing the image size — enough to learn
/// what the glasses send before recognition is built.
@MainActor
@Observable
final class GlassesFaceLink {
    static let shared = GlassesFaceLink()

    private(set) var imagesReceived = 0
    private(set) var lastImage: String?

    /// Most images kept for inspection.
    static let keepImages = 40

    private var observer: UUID?
    private var sendChain: Task<Void, Never>?
    private var lastCard = Date.distantPast
    private let folder: URL = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true))
        .map { $0.appendingPathComponent("FaceLinkProbe", isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("FaceLinkProbe", isDirectory: true)

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
            post(GlassesFaceLinkWire.prepared(true))
        case .image(let image):
            imagesReceived += 1
            lastImage = "\(image.width)×\(image.height) · \(image.data.count) bytes · type \(image.kind)"
            if imagesReceived == 1 || imagesReceived % 10 == 0 {
                InmoRuntimeDiagnostics.note("face link image #\(imagesReceived) \(lastImage ?? "")")
            }
            post(GlassesFaceLinkWire.imageReceived(timestamp: image.timestamp))
            keep(image)
            // One card at a time: the lens needs a moment to show it.
            if Date().timeIntervalSince(lastCard) >= 1.5 {
                lastCard = Date()
                post(GlassesFaceLinkWire.identified(name: "Jarvis Face Link", job: "Image \(imagesReceived) received",
                                                    company: "\(image.width)×\(image.height)", similarity: 0.99))
            }
        }
    }

    private func keep(_ image: GlassesFaceLinkWire.Image) {
        guard imagesReceived <= Self.keepImages else { return }
        let ext: String
        if image.data.starts(with: [0xff, 0xd8]) { ext = "jpg" }
        else if image.data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { ext = "png" }
        else { ext = "bin" }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(image.timestamp)_\(image.width)x\(image.height)_\(imagesReceived).\(ext)"
            try image.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            InmoRuntimeDiagnostics.note("face link could not keep image: \(error.localizedDescription)")
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

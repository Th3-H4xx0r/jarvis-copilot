import Foundation

/// Where Live captions go on the lens. One app owns the lens at a time.
@MainActor
protocol LensCaptionSurface: AnyObject {
    /// The lens app (SWITCHAPP id) this surface opens.
    var module: Int { get }
    func open()
    func show(_ caption: LensCaption)
    func close()
}

enum LensCaptionStyle: String, CaseIterable, Identifiable {
    /// The glasses' own Subtitles app (lens app 8).
    case subtitles
    /// The translation app (lens app 0): the line and its translation.
    case translation
    var id: String { rawValue }
    var label: String { self == .subtitles ? "Subtitles" : "Translation" }
    @MainActor func makeSurface() -> LensCaptionSurface {
        self == .subtitles ? SubtitlesSurface() : TranslationAppSurface()
    }
}

/// Sends in order: BLE writes are queued behind one another.
@MainActor
final class LensSendQueue {
    /// One queue for every surface, so a close on one style and an open on the
    /// other reach the glasses in the order they were made.
    static let shared = LensSendQueue()
    private var chain: Task<Void, Never>?
    func post(_ message: Data) {
        let previous = chain
        chain = Task {
            await previous?.value
            do { try await InmoSession.shared.send(message) } catch {
                InmoRuntimeDiagnostics.note("live captions send failed: \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
final class SubtitlesSurface: LensCaptionSurface {
    let module = GlassesSubtitlesWire.module
    private let queue = LensSendQueue.shared
    func open() {
        queue.post(InmoCommand.openModule(module))
        queue.post(GlassesSubtitlesWire.start())
    }
    /// The translation rides on a second line of the same caption.
    func show(_ caption: LensCaption) {
        let text = caption.translation.isEmpty ? caption.text : caption.text + "\n" + caption.translation
        queue.post(GlassesSubtitlesWire.line(text, final: caption.final))
    }
    func close() {
        queue.post(GlassesSubtitlesWire.stop())
        queue.post(InmoCommand.closeModule(module))
    }
}

@MainActor
final class TranslationAppSurface: LensCaptionSurface {
    let module = GlassesTranslateWire.Mode.simultaneous.module
    private let queue = LensSendQueue.shared
    func open() {
        queue.post(InmoCommand.openModule(module))
        // Captions are not a language pair: the header shows the device language twice.
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        queue.post(GlassesTranslateWire.setting(mode: .simultaneous, source: language, target: language))
    }
    func show(_ caption: LensCaption) {
        queue.post(GlassesTranslateWire.line(original: caption.text, translation: caption.translation, finished: caption.final))
    }
    func close() {
        queue.post(GlassesTranslateWire.saved())
        queue.post(InmoCommand.closeModule(module))
    }
}

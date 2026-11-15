import AppIntents
import Foundation

/// "Holo Drop Screen": what Back Tap and the Control Center button run, through a Shortcut that
/// grabs what's on screen (Get What's On Screen + Take Screenshot) and hands both here. A photo
/// or video open in Photos goes as itself. Anything else goes as the screenshot, plus the web
/// page in it when Jarvis recognises one ("best guess").
struct HoloDropScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Holo Drop Screen"
    static let description = IntentDescription(
        "Drop what's on screen onto another device: the photo you're looking at, or a screenshot.")
    static let openAppWhenRun = true

    /// Optional: run on its own (no screenshot step) it says to re-add the shortcut.
    @Parameter(title: "Screenshot")
    var image: IntentFile?

    /// What "Get What's On Screen" gave: Photos hands over the open photo itself.
    @Parameter(title: "On screen")
    var onScreen: IntentFile?

    /// No reply: a Siri reply (even an empty one) leaves a "Done" card over the screen after Back Tap.
    @MainActor
    func perform() async throws -> some IntentResult {
        guard PowerState.shared.isOn("holo-drop") else { return .result() }
        if let onScreen, let item = Self.photo(onScreen) {
            HoloLauncher.shared.present(item)
            return .result()
        }
        guard let image else {
            // Run without a screenshot (an old shortcut with no Take Screenshot step): say so,
            // rather than silently sending the wrong photo.
            HoloLauncher.shared.openQuick(note: "No screenshot came in — add the shortcut again from the Holo Drop page")
            return .result()
        }
        let name = "Screenshot \(Date().formatted(.dateTime.hour().minute().second())).png"
            .replacingOccurrences(of: ":", with: ".")
        let dir = HoloTemp.root.appendingPathComponent("screen-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try image.data.write(to: url)
        // Open at once with the screenshot; if it shows a photo from his library, swap in the original.
        let model = HoloLauncher.shared.present(.file(url, name: name, mime: "image/png", kind: "image"), guessFrom: url)
        Task { @MainActor in
            guard let asset = await HoloScreenPhoto.findOriginal(for: url),
                  let original = await HoloQuickPick.export(asset),
                  let model, model.phase == .choosing || model.phase == .loading else { return }
            model.item = original
            model.extra = nil                                  // a photo, not a web page: no best-guess link
            model.errorText = "Sending the original photo"
        }
        return .result()
    }

    /// The on-screen item as a photo/video to send, or nil (a page, a place, nothing).
    @MainActor
    private static func photo(_ file: IntentFile) -> HoloItem? {
        let dir = HoloTemp.root.appendingPathComponent("onscreen-\(UUID().uuidString.prefix(6))", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        if let src = file.fileURL {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            if let item = HoloScreenPhoto.onScreenItem(file: src, filename: file.filename, type: file.type, in: dir) {
                return item
            }
        }
        return HoloScreenPhoto.onScreenItem(data: file.data, filename: file.filename, type: file.type, in: dir)
    }
}

/// "Open Holo Drop" from Shortcuts/Siri: the Holo Drop page.
struct OpenHoloDropIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Holo Drop"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        HoloLauncher.shared.openQuick()
        return .result()
    }
}

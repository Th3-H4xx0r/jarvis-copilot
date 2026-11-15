import AppIntents
import Foundation

/// "Holo Drop Screen": what Back Tap and the Control Center button run, through a Shortcut that
/// takes a screenshot and hands it here. Opens Jarvis on the Orbit with the screenshot; when
/// Jarvis recognises the web page in it, that link goes along too, marked "best guess".
struct HoloDropScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Holo Drop Screen"
    static let description = IntentDescription(
        "Drop a screenshot onto another device — and the page it shows, when Jarvis recognises it.")
    static let openAppWhenRun = true

    /// Optional: run on its own (no screenshot step) it opens Holo Drop with the newest photo.
    @Parameter(title: "Screenshot")
    var image: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PowerState.shared.isOn("holo-drop") else { return .result(dialog: "Holo Drop is switched off.") }
        guard let image else {
            HoloLauncher.shared.openQuick()
            return .result(dialog: "")
        }
        let name = "Screenshot \(Date().formatted(.dateTime.hour().minute().second())).png"
            .replacingOccurrences(of: ":", with: ".")
        let dir = HoloTemp.root.appendingPathComponent("screen-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try image.data.write(to: url)
        HoloLauncher.shared.present(.file(url, name: name, mime: "image/png", kind: "image"), guessFrom: url)
        return .result(dialog: "")
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

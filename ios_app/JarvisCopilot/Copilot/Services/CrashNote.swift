import Foundation

/// The last crash, in the app's own container: what iOS ends the app over
/// (an Objective-C exception from HealthKit, MapKit…) never reaches a Swift
/// `catch`, so the reason is written down as it happens and read afterwards.
enum CrashNote {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-crash.txt")
    }

    /// Installed once, at launch.
    static func watch() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            \(Date())
            \(exception.name.rawValue): \(exception.reason ?? "no reason")
            \(exception.userInfo.map { "\($0)" } ?? "")
            \(exception.callStackSymbols.prefix(24).joined(separator: "\n"))
            """
            try? text.write(to: CrashNote.url, atomically: true, encoding: .utf8)
        }
    }

    /// What it said last time (nil when the app has never crashed here).
    static func read() -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

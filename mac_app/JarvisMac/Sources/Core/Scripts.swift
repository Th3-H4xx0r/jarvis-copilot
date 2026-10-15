import Foundation

/// Every AppleScript the app runs goes through one serial background queue:
/// a busy Music or Mail, or a first-time Automation consent dialog, must never
/// freeze the island, and two scripts never run at once.
enum Scripts {
    private static let queue = DispatchQueue(label: "jarvis.applescript", qos: .userInitiated)

    struct Result: Sendable {
        let output: String?
        let error: String?
        var ok: Bool { error == nil }
    }

    static func run(_ source: String) async -> Result {
        await withCheckedContinuation { cont in
            queue.async {
                var err: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
                let message = err.map { ($0[NSAppleScript.errorMessage] as? String) ?? "AppleScript error" }
                cont.resume(returning: Result(output: message == nil ? (out?.stringValue ?? "") : nil, error: message))
            }
        }
    }

    /// Fire and forget, still in order with the others.
    static func launch(_ source: String) {
        queue.async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
    }
}

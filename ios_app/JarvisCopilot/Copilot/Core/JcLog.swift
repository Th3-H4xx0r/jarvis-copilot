import Foundation
import os

/// One place for diagnostics. Every swallowed error in the port should at least land
/// here so a support log can tell a 401 from a parse failure. Categories are per area.
enum JcLog {
    static let subsystem = "com.jarviscopilot.jarviscopilotMobileAndIOS"

    static let core = Logger(subsystem: subsystem, category: "core")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let coding = Logger(subsystem: subsystem, category: "coding")
    static let skills = Logger(subsystem: subsystem, category: "skills")
    static let more = Logger(subsystem: subsystem, category: "more")
    static let services = Logger(subsystem: subsystem, category: "services")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Log an error with context and return the user-facing line, so call sites can
    /// write `error = JcLog.report(.chat, "send", error)`.
    @discardableResult
    static func report(_ logger: Logger, _ context: StaticString, _ error: Error) -> String {
        let message = apiErrorLine(error)
        logger.error("\(context, privacy: .public): \(message, privacy: .public) [\(String(describing: type(of: error)), privacy: .public)]")
        return message
    }

    /// For `try?` sites that intentionally keep going: record what was dropped.
    static func dropped(_ logger: Logger, _ context: StaticString, _ error: Error) {
        logger.warning("\(context, privacy: .public) (ignored): \(apiErrorLine(error), privacy: .public)")
    }
}

import Foundation

/// One dictation, kept for the Flow window's history.
struct FlowEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
    /// The app it was pasted in ("Slack"), when known.
    var app: String?
    var words: Int
    /// How long you spoke.
    var seconds: Double
}

/// The numbers of one day. Kept when the history is emptied, so Stats stay right.
struct FlowDayStats: Codable, Equatable, Sendable {
    var words = 0
    var seconds = 0.0
    var dictations = 0
}

struct FlowStats: Codable, Equatable, Sendable {
    /// "2026-10-14" → that day's numbers.
    var days: [String: FlowDayStats] = [:]
    /// App name → words dictated in it.
    var apps: [String: Int] = [:]

    mutating func add(words: Int, seconds: Double, app: String?, day: String) {
        guard words > 0 else { return }
        var d = days[day] ?? FlowDayStats()
        d.words += words
        d.seconds += seconds
        d.dictations += 1
        days[day] = d
        if let app, !app.isEmpty { apps[app, default: 0] += words }
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }
}

/// How the words are written in an app when the clean-up is on.
enum FlowStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Only the dictionary, replacements and snippets: code, terminals, AI chats.
    case verbatim
    /// Without the "uh"s and the repeats, punctuation fixed, the tone kept.
    case natural
    /// Full sentences, for mail.
    case polished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .verbatim: return String(localized: "As said")
        case .natural: return String(localized: "Natural")
        case .polished: return String(localized: "Polished")
        }
    }

    var detail: String {
        switch self {
        case .verbatim: return String(localized: "Your words exactly, with the dictionary and snippets. For code and terminals.")
        case .natural: return String(localized: "Without the fillers and repeats, punctuation fixed, your tone kept.")
        case .polished: return String(localized: "Clean full sentences, for email.")
        }
    }

    /// The style of the app the words go to.
    static func resolve(bundleID: String?, in styles: [FlowAppStyle], default fallback: FlowStyle) -> FlowStyle {
        guard let bundleID else { return fallback }
        return styles.first(where: { $0.bundleID == bundleID })?.style ?? fallback
    }
}

/// An app with its own style.
struct FlowAppStyle: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var style: FlowStyle
    var id: String { bundleID }

    /// Apps that get a style from the start: mail polished, chats natural, code
    /// and AI chats as said.
    static let defaults: [FlowAppStyle] = [
        FlowAppStyle(bundleID: "com.apple.mail", name: "Mail", style: .polished),
        FlowAppStyle(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", style: .natural),
        FlowAppStyle(bundleID: "com.apple.MobileSMS", name: "Messages", style: .natural),
        FlowAppStyle(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", style: .natural),
        FlowAppStyle(bundleID: "com.anthropic.claudefordesktop", name: "Claude", style: .verbatim),
        FlowAppStyle(bundleID: "com.apple.Terminal", name: "Terminal", style: .verbatim),
        FlowAppStyle(bundleID: "com.googlecode.iterm2", name: "iTerm", style: .verbatim),
        FlowAppStyle(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", style: .verbatim),
        FlowAppStyle(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", style: .verbatim),
    ]
}

/// How long the history is kept.
enum FlowHistory {
    static let defaultKeepDays = 30

    /// `keepDays`: 0 = not kept, -1 = forever.
    static func pruned(_ entries: [FlowEntry], keepDays: Int, now: Date = Date()) -> [FlowEntry] {
        if keepDays == 0 { return [] }
        guard keepDays > 0 else { return entries }
        let limit = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return entries.filter { $0.date >= limit }
    }
}

/// The engine that turns speech into text.
enum FlowEngine: String, CaseIterable, Identifiable {
    /// Apple's SpeechAnalyzer on macOS 26 when the Mac has it, else the on-device recognizer.
    case automatic
    /// The on-device SFSpeechRecognizer only.
    case classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return String(localized: "Apple Speech (newest available)")
        case .classic: return String(localized: "Apple on-device recognizer")
        }
    }
}

import Foundation

/// Apple Mail's inbox as the island shows it: the unread count and the newest
/// messages. Read by AppleScript only while the Mail tab is open.
struct MailInbox: Equatable {
    struct Message: Equatable, Identifiable {
        let id: Int
        var isRead: Bool
        let sender: String
        let subject: String
        let received: Date?

        /// "Ada" from "Ada <ada@example.com>", else the address.
        var senderName: String {
            if let lt = sender.firstIndex(of: "<") {
                let name = sender[..<lt].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty { return name }
            }
            return sender
        }
    }

    var unread: Int
    var messages: [Message]

    static let recordSeparator = "\u{1E}"
    static let unitSeparator = "\u{1F}"

    /// `unread RS id US read US sender US subject US iso-date RS …` (see MailScript.inbox).
    static func parse(_ raw: String) -> MailInbox {
        let records = raw.components(separatedBy: recordSeparator).filter { !$0.isEmpty }
        guard let first = records.first, let unread = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return MailInbox(unread: 0, messages: [])
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        iso.timeZone = .current
        let messages: [Message] = records.dropFirst().compactMap { r in
            let f = r.components(separatedBy: unitSeparator)
            guard f.count >= 5, let id = Int(f[0]) else { return nil }
            return Message(id: id, isRead: f[1] == "true", sender: f[2], subject: f[3], received: iso.date(from: f[4]))
        }
        return MailInbox(unread: unread, messages: messages)
    }
}

/// The AppleScript the Mail tab runs. Every string that goes into a script
/// passes through `quote`.
enum MailScript {
    static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let lines = escaped.components(separatedBy: .newlines)
        return lines.map { "\"\($0)\"" }.joined(separator: " & linefeed & ")
    }

    static func recipients(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",; \n\t")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func inbox(limit: Int = 12) -> String {
        """
        tell application "Mail"
            set rs to (character id 30)
            set us to (character id 31)
            set out to ((unread count of inbox) as string) & rs
            set n to count of messages of inbox
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set m to message i of inbox
                set d to date received of m
                set out to out & (id of m as string) & us & (read status of m as string) & us & (sender of m) & us & (subject of m) & us & (d as «class isot» as string) & rs
            end repeat
            return out
        end tell
        """
    }

    private static func message(_ id: Int) -> String { "(first message of inbox whose id is \(id))" }

    static func markRead(_ id: Int) -> String {
        "tell application \"Mail\" to set read status of \(message(id)) to true"
    }

    static func reply(_ id: Int) -> String {
        "tell application \"Mail\"\nactivate\nreply \(message(id)) with opening window\nend tell"
    }

    static func open(_ id: Int) -> String {
        "tell application \"Mail\"\nactivate\nopen \(message(id))\nend tell"
    }

    /// A new message in Mail; sent only when `send` is true (the Send button),
    /// else left open for you.
    static func compose(to: [String], subject: String, body: String, send: Bool) -> String {
        var s = "tell application \"Mail\"\n"
        s += "set m to make new outgoing message with properties {subject:\(quote(subject)), content:\(quote(body)), visible:\(send ? "false" : "true")}\n"
        for a in to {
            s += "tell m to make new to recipient at end of to recipients with properties {address:\(quote(a))}\n"
        }
        s += send ? "send m\n" : "activate\n"
        return s + "end tell"
    }
}

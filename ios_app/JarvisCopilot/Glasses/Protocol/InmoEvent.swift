import Foundation

enum InmoEvent { case message(type: Int, fields: [InmoWireField], raw: Data); case connectionChanged(InmoConnectionState) }
/// An incoming call the glasses relay (MESSAGE_REMINDER USER_CALL_INFO): the number
/// they got over hands-free, any name already attached, and the call state.
struct InmoCallInfo: Equatable {
    let number: String
    let name: String?
    let state: Int
    static func parse(_ fields: [InmoWireField]) -> InmoCallInfo? {
        guard let reminder = try? fields.firstField(7)?.nested(), reminder.firstField(1)?.varint == 1,
              let notif = try? reminder.firstField(3)?.nested() else { return nil }
        func text(_ tag: Int) -> String? {
            guard let inner = try? notif.firstField(tag)?.nested(), let bytes = inner.firstField(1)?.bytes, !bytes.isEmpty else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        guard let number = text(2) else { return nil }
        return InmoCallInfo(number: number, name: text(1), state: Int(notif.firstField(4)?.varint ?? 0))
    }
}
/// One-line description of an incoming MESSAGE_REMINDER(4) for diagnostics: the
/// kind, the app and the sizes — never the notification text or a phone number.
enum InmoReminderSummary {
    static func describe(_ fields: [InmoWireField]) -> String {
        guard let reminder = try? fields.firstField(7)?.nested() else { return "incoming reminder (unreadable)" }
        var parts = ["incoming reminder kind=\(reminder.firstField(1)?.varint ?? 0)"]
        if let info = try? reminder.firstField(2)?.nested() {
            let app = info.firstField(1)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            parts.append("app=\(app) title=\(info.firstField(3)?.bytes?.count ?? 0)B content=\(info.firstField(4)?.bytes?.count ?? 0)B")
        }
        if let call = try? reminder.firstField(3)?.nested() { parts.append("call state=\(call.firstField(4)?.varint ?? 0)") }
        return parts.joined(separator: " ")
    }
}
struct InmoDeviceStatus {
    var battery: Int?
    var batteryObservedAt: Date?
    var brightness: Int?
    var volume: Int?
    var dnd: Bool?
    var screenTimeoutSelector: Int?
    var firmware: String?
    var model: String?
    var serial: String?
    var module: Int?
    var lastReceived: Date?
    mutating func apply(type: Int, fields: [InmoWireField], now: Date = Date()) throws {
        if type == 15, let nested = fields.firstField(18) {
            let raw = try nested.nested().firstField(1)?.varint ?? 0
            guard let value = Int(exactly: raw) else { throw InmoProtocolError.malformed("Invalid module value") }
            module = value
        }
        guard type == 20, let status = fields.firstField(23) else { return }
        let f = try status.nested()
        func value(_ tag: Int) throws -> UInt64? { guard let field = f.firstField(tag) else { return nil }; return try field.nested().firstField(1)?.varint ?? 0 }
        func text(_ tag: Int) throws -> String? { guard let field = f.firstField(tag) else { return nil }; return try field.nested().firstField(1)?.bytes.flatMap { String(data: $0, encoding: .utf8) } }
        if let v = try value(8), v <= 100 { battery = Int(v); batteryObservedAt = now }
        if let v = try value(7), v <= 100 { brightness = Int(v) }
        if let v = try value(9), v <= 100 { volume = Int(v) }
        if let v = try value(16) { dnd = v != 0 }
        if let v = try value(4) {
            guard let selector = Int(exactly: v) else { throw InmoProtocolError.malformed("Invalid timeout selector") }
            screenTimeoutSelector = selector
        }
        if let v = try text(2) { firmware = v }; if let v = try text(3) { serial = v }; if let v = try text(12) { model = v }
        lastReceived = now
    }
}

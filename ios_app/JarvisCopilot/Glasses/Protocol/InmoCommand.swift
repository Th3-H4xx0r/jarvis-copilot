import Foundation

enum InmoCommand {
    static func envelope(type: Int, field: Int, payload: Data, version: Int? = nil) -> Data {
        (version.map { InmoWireCodec.uint(1, UInt64($0)) } ?? Data()) + InmoWireCodec.uint(2, UInt64(type)) + InmoWireCodec.bytes(field, payload)
    }
    static func control(_ type: Int, field: Int? = nil, payload: Data = Data()) -> Data {
        envelope(type: 2, field: 5, payload: InmoWireCodec.uint(1, UInt64(type)) + (field.map { InmoWireCodec.bytes($0, payload) } ?? Data()), version: 1)
    }
    static func home() -> Data { control(5) }
    static func back() -> Data { control(4) }
    /// The remote's GO button: Control{CommandType.GO_INDEX(7)}, beside BACK_INDEX(4) and HOME_INDEX(5).
    static func go() -> Data { control(7) }
    /// The GO key as the INMO app's remote sends it: one raw key event (press on finger down, release
    /// on lift) — Control{TOUCH_CTRL(20), 13: CommandTouchCtrl{source APP(1), key GO(4), state, systick}}.
    /// The glasses tell single, double and long presses apart from these, so a double press needs them.
    static func goKey(pressed: Bool, atMillis millis: UInt64) -> Data {
        let event = InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(2, 4)
            + (pressed ? InmoWireCodec.uint(3, 1) : Data()) + InmoWireCodec.uint(4, millis)
        return control(20, field: 13, payload: event)
    }
    /// Two taps the way the INMO app sends them (captured 2026-10-01): each press held ~30 ms, the
    /// second ~180 ms after the first. Offsets are from the start, not between writes, so the write
    /// acknowledgements can't stretch the taps past the glasses' double-click window.
    static func goDoublePress(startMillis: UInt64) -> [(bytes: Data, offsetMillis: UInt64)] {
        let events: [(Bool, UInt64)] = [(true, 0), (false, 30), (true, 180), (false, 210)]
        return events.map { pressed, offset in (goKey(pressed: pressed, atMillis: startMillis + offset), offset) }
    }
    static func touch(kind: Int, direction: Int?, x: Int, y: Int) throws -> Data {
        guard (1...2).contains(kind), (0...100).contains(x), (0...100).contains(y), direction == nil || (0...3).contains(direction!) else { throw InmoProtocolError.malformed("Invalid touch gesture") }
        return control(8, field: 8, payload: InmoWireCodec.uint(1, UInt64(kind)) + (direction.map { InmoWireCodec.uint(2, UInt64($0)) } ?? Data()) + InmoWireCodec.uint(3, UInt64(x)) + InmoWireCodec.uint(4, UInt64(y)))
    }
    static func brightness(_ value: Int) throws -> Data { try percentage(value, type: 1, field: 5) }
    static func volume(_ value: Int) throws -> Data { try percentage(value, type: 0, field: 4) }
    private static func percentage(_ value: Int, type: Int, field: Int) throws -> Data {
        guard (0...100).contains(value) else { throw InmoProtocolError.malformed("Value must be 0–100") }
        return control(type, field: field, payload: InmoWireCodec.uint(1, UInt64(value)))
    }
    static func dnd(_ enabled: Bool) -> Data { envelope(type: 19, field: 22, payload: InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(2, enabled ? 1 : 0, includeZero: true), version: 1) }
    static func screenTimeout(seconds: Int) throws -> Data {
        guard let selector = [15: 0, 30: 1][seconds] else { throw InmoProtocolError.unavailable("Only observed 15 and 30 second timeouts are enabled") }
        return settings(type: 9, field: 5, value: UInt64(selector))
    }
    static func settings(type: Int, field: Int, value: UInt64) -> Data { envelope(type: 19, field: 22, payload: InmoWireCodec.uint(1, UInt64(type)) + (field == 2 ? InmoWireCodec.uint(field, value, includeZero: true) : InmoWireCodec.bytes(field, InmoWireCodec.uint(1, value))), version: 1) }
    /// Tells the GO3 firmware to consume iOS ANCS — i.e. show the phone's own
    /// notifications on the lens the way a Garmin watch does, with iOS as the
    /// provider and the glasses as the GATT consumer (no app relay). Encodes
    /// `GlassesSettings{msgType: IOS_ANCS_ENABLE(24), isOpen}`, identical to the
    /// Android `getGlassesSettingsCommonMessage(24, isOpen)`. This is a schema
    /// composition — the shipped Android app never builds it (Android uses
    /// NotificationListenerService instead) — so it is unverified until a live
    /// hardware test confirms notifications appear.
    static func iosAncsEnable(_ enabled: Bool) -> Data { settings(type: 24, field: 2, value: enabled ? 1 : 0) }
    /// One entry in the per-app notification list the official INMO iOS app keeps
    /// on the glasses, keyed by the app's display name ("Gmail", not a bundle id):
    /// `GlassesSettings{msgType: MOBILE_NOTIFY_CIRCULATION_MODEL(15), 11: {1: appName, 2: isOpen}}`.
    /// Switching an app off omits isOpen, as the official app does.
    static func notificationApp(_ name: String, enabled: Bool) -> Data {
        let model = InmoWireCodec.bytes(1, Data(name.utf8)) + (enabled ? InmoWireCodec.uint(2, 1) : Data())
        return envelope(type: 19, field: 22, payload: InmoWireCodec.uint(1, 15) + InmoWireCodec.bytes(11, model), version: 1)
    }
    /// Pushes a notification card for the glasses to display on the lens, over the
    /// vendor MESSAGE_REMINDER(4) channel — the same path the Android app uses to
    /// draw notifications it reads from the phone. MessageReminder carries an
    /// AppNotificationInfo{1:packageName, 2:type, 3:title, 4:content, 5:time(ms)}
    /// at field 2 (msgType APP_NOTIFICATION_INFO=0 is the proto3 default, omitted).
    static func appNotification(title: String, content: String, packageName: String = "com.jarviscopilot", type: Int = 0, timeMillis: UInt64? = nil) -> Data {
        let millis = timeMillis ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let info = InmoWireCodec.bytes(1, Data(packageName.utf8))
            + (type != 0 ? InmoWireCodec.uint(2, UInt64(type)) : Data())
            + InmoWireCodec.bytes(3, Data(title.utf8))
            + InmoWireCodec.bytes(4, Data(content.utf8))
            + InmoWireCodec.uint(5, millis)
        return envelope(type: 4, field: 7, payload: InmoWireCodec.bytes(2, info), version: 1)
    }
    /// Answers the glasses' incoming-call relay with the contact's name, as the
    /// official app does: MESSAGE_REMINDER{USER_CALL_INFO(1), 3: MobilePhoneNotif{
    /// 1: ContactName{1: name}, 2: UserList{1: number}, 4: call state}}, no version field.
    static func callInfo(name: String, number: String, state: Int) -> Data {
        let notif = InmoWireCodec.bytes(1, InmoWireCodec.bytes(1, Data(name.utf8)))
            + InmoWireCodec.bytes(2, InmoWireCodec.bytes(1, Data(number.utf8)))
            + InmoWireCodec.uint(4, UInt64(state))
        return envelope(type: 4, field: 7, payload: InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, notif))
    }
    static func openModule(_ module: Int) -> Data { envelope(type: 15, field: 18, payload: InmoWireCodec.uint(1, UInt64(module))) }
    static func closeModule(_ module: Int) -> Data { envelope(type: 15, field: 18, payload: InmoWireCodec.uint(1, UInt64(module)) + InmoWireCodec.uint(2, 1)) }
    static func mediaInventory() -> Data { envelope(type: 17, field: 20, payload: InmoWireCodec.uint(1, 4) + InmoWireCodec.bytes(6, InmoWireCodec.uint(1, 4))) }
    static func wifi(open: Bool) -> Data { envelope(type: 17, field: 20, payload: InmoWireCodec.uint(1, 3) + InmoWireCodec.bytes(5, InmoWireCodec.uint(1, open ? 0 : 1, includeZero: true))) }
    static func queryStatus() -> Data { envelope(type: 17, field: 20, payload: InmoWireCodec.uint(1, 3) + InmoWireCodec.bytes(11, Data()), version: 1) }
    static func reconnect(owner: Data) -> Data { envelope(type: 24, field: 27, payload: InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(2, owner) + InmoWireCodec.uint(3, 1), version: 1) }
    static func enableClassicGATT() -> Data { envelope(type: 17, field: 20, payload: InmoWireCodec.uint(1, 3) + InmoWireCodec.uint(10, 0, includeZero: true), version: 1) }
}

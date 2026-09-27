import Foundation

/// The GO3 Navigation app's protocol, spoken the way the official Android app does
/// (inmo-re/notes/go3-navigation-flow.md): Message{2: NAVIGATION(33), 36: Navigation{
/// 1: subtype, N: payload}}, no version field, zero values omitted. Distances are
/// metres, times seconds, the ETA "HH:mm"; countryCode is the destination's ISO
/// alpha-3 code ("USA" is what switches the lens to feet/miles).
enum InmoNavigationWire {
    struct Address: Equatable { var index: Int64; var type: Int; var name: String; var detail: String }
    struct Plan: Equatable { var achievable: Bool; var seconds: Int64; var meters: Int64 }
    enum Incoming: Equatable { case start(type: Int, index: Int64); case selected(walking: Bool) }

    private static func navigation(_ subtype: Int, field: Int, _ payload: Data) -> Data {
        InmoCommand.envelope(type: 33, field: 36, payload: InmoWireCodec.uint(1, UInt64(subtype)) + InmoWireCodec.bytes(field, payload))
    }
    private static func text(_ field: Int, _ value: String) -> Data { value.isEmpty ? Data() : InmoWireCodec.bytes(field, Data(value.utf8)) }
    private static func count(_ field: Int, _ value: Int64) -> Data { InmoWireCodec.uint(field, UInt64(max(0, value))) }

    /// Answer to the glasses' SUPPORTED_MODULES(35) question: Message{38: {1: packed module list}}.
    /// 2 = Navigation (1 scenic guide, 3 call translation are not served by Jarvis).
    static func supportedModules(_ modules: [Int]) -> Data {
        let packed = modules.reduce(Data()) { $0 + InmoWireCodec.varint(UInt64($1)) }
        return InmoCommand.envelope(type: 35, field: 38, payload: InmoWireCodec.bytes(1, packed))
    }
    /// The saved places the lens lists (home 0, work 1, other 2). Sent even when empty.
    static func addresses(_ list: [Address]) -> Data {
        let body = list.reduce(Data()) { data, a in
            data + InmoWireCodec.bytes(1, count(1, a.index) + InmoWireCodec.uint(2, UInt64(a.type)) + text(3, a.name) + text(4, a.detail))
        }
        return navigation(3, field: 5, body)
    }
    /// "Can't navigate" (no location permission, GPS off, no route to a place).
    static func permission(_ granted: Bool) -> Data { navigation(5, field: 7, InmoWireCodec.uint(1, granted ? 1 : 0)) }
    /// Cycling and walking options for the chosen place.
    static func routePlanning(cycling: Plan, walking: Plan, countryCode: String) -> Data {
        func plan(_ p: Plan) -> Data { InmoWireCodec.uint(1, p.achievable ? 1 : 0) + count(2, p.seconds) + count(3, p.meters) }
        return navigation(6, field: 8, InmoWireCodec.bytes(1, plan(cycling)) + InmoWireCodec.bytes(2, plan(walking)) + text(3, countryCode))
    }
    /// The next maneuver: GO3 turn type (HERE ManeuverAction numbering), road, metres to it.
    static func guide(type: Int, road: String, meters: Int64, countryCode: String) -> Data {
        navigation(0, field: 2, InmoWireCodec.uint(1, UInt64(type)) + text(2, road) + count(3, meters) + text(4, countryCode))
    }
    static func remaining(meters: Int64, seconds: Int64, reachTime: String, countryCode: String) -> Data {
        navigation(1, field: 3, count(1, meters) + count(2, seconds) + text(3, reachTime) + text(4, countryCode))
    }
    /// The heading-up minimap, 211×121 PNG, green on black.
    static func image(_ png: Data) -> Data { navigation(2, field: 4, InmoWireCodec.bytes(1, png)) }
    static func arrived(meters: Int64, seconds: Int64, countryCode: String, image: Data?) -> Data {
        navigation(10, field: 12, count(1, meters) + count(2, seconds) + text(3, countryCode) + (image.map { InmoWireCodec.bytes(4, $0) } ?? Data()))
    }

    /// The glasses' navigation requests: a place picked on the lens (only type and
    /// index matter — the phone keeps the coordinates) or the chosen mode (0 cycling, 1 walking).
    static func incoming(_ fields: [InmoWireField]) -> Incoming? {
        guard fields.firstField(2)?.varint == 33, let nav = try? fields.firstField(36)?.nested() else { return nil }
        switch nav.firstField(1)?.varint ?? 0 {
        case 4:
            let address = (try? nav.firstField(6)?.nested())?.firstField(1).flatMap { try? $0.nested() } ?? []
            return .start(type: Int(address.firstField(2)?.varint ?? 0), index: Int64(bitPattern: address.firstField(1)?.varint ?? 0))
        case 7:
            let selected = (try? nav.firstField(9)?.nested()) ?? []
            return .selected(walking: selected.firstField(1)?.varint == 1)
        default: return nil
        }
    }
    /// The glasses opening (true) or leaving (false) their Navigation app:
    /// STARTING_APPLICATION(15){18: {1: SWITCHPP_NAVIGATION(13), 2: open 0 | close 1}}.
    static func appSwitch(_ fields: [InmoWireField]) -> Bool? {
        guard fields.firstField(2)?.varint == 15, let app = try? fields.firstField(18)?.nested(), app.firstField(1)?.varint == 13 else { return nil }
        return (app.firstField(2)?.varint ?? 0) == 0
    }
}

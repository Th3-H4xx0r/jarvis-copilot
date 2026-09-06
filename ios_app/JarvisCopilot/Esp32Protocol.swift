import Foundation
import CoreBluetooth

/// Wire protocol for the Jarvis ESP32 board. Byte-for-byte mirror of
/// `firmware/JarvisEsp32/Protocol.h`; change both or neither.
///
/// Frame: `A5 | LEN | OP | PAYLOAD… | CRC` where LEN counts OP+PAYLOAD and CRC is
/// CRC-8 (poly 0x07) over LEN, OP and PAYLOAD. The same frames travel over BLE (one
/// frame per write / notification) and over a raw TCP socket (byte stream).
enum Esp32Protocol {
    static let version: UInt8 = 3

    static let service = CBUUID(string: "F0E1D2C3-0001-4A56-8000-4A6172766973")
    static let commandCharacteristic = CBUUID(string: "F0E1D2C3-0002-4A56-8000-4A6172766973")
    static let eventCharacteristic = CBUUID(string: "F0E1D2C3-0003-4A56-8000-4A6172766973")

    /// Advertised local name is `<prefix>-XXXX` with the last two MAC bytes.
    static let namePrefix = "Jarvis-ESP32"
    static let tcpPort: UInt16 = 4711
    static let bonjourType = "_jarvis-esp32._tcp"

    static let sync: UInt8 = 0xA5
    static let responseBit: UInt8 = 0x80
    static let maxBody = 240
    static let maxFrame = 3 + maxBody
    static let tokenLength = 16
    static let maxSSIDLength = 32
    static let maxPasswordLength = 64

    enum Op: UInt8 {
        case ping = 0x01, getInfo = 0x02, getState = 0x03
        case ledSet = 0x10, ledBlink = 0x11
        case pinMode = 0x20, pinWrite = 0x21, pinRead = 0x22, pinPWM = 0x23, pinPulse = 0x24
        case allOff = 0x2F
        case wifiSet = 0x40, wifiStatus = 0x41, wifiForget = 0x42, auth = 0x44, claim = 0x45, wifiScan = 0x46, resetOwner = 0x47
        case cloudSet = 0x48, cloudStatus = 0x49, cloudForget = 0x4A, cloudPause = 0x4B
        case scriptBegin = 0x50, scriptChunk = 0x51, scriptCommit = 0x52, scriptStop = 0x53, scriptStart = 0x54
        case scriptStatus = 0x55, scriptDelete = 0x56, jarvisResult = 0x57
    }

    enum Event: UInt8 {
        case inputChanged = 0xE1, pulseDone = 0xE2, blinkDone = 0xE3, wifiChanged = 0xE4
        case scriptOutput = 0xE5, jarvisCall = 0xE6, scriptState = 0xE7, cloudChanged = 0xE8
    }

    enum CloudState: UInt8 {
        case off = 0, paired, connecting, connected, failed, expired

        var label: String {
            switch self {
            case .off:        return "Off"
            case .paired:     return "Standby"
            case .connecting: return "Connecting…"
            case .connected:  return "Connected"
            case .failed:     return "Failed"
            case .expired:    return "Expired"
            }
        }
    }

    struct CloudStatus: Hashable {
        let state: CloudState
        /// True when the board boots without Bluetooth and holds the bridge itself.
        let cloudMode: Bool
        let server: String
        let error: String
    }

    enum Status: UInt8 {
        case ok = 0, badFrame, unknownOp, badPin, badArg, notCapable, busy, unauthorized, wrongLink, alreadyClaimed, scanning, scriptError

        var label: String {
            switch self {
            case .ok:           return "ok"
            case .badFrame:     return "board rejected the frame (CRC)"
            case .unknownOp:    return "board does not know that command"
            case .badPin:       return "that GPIO is not exposed"
            case .badArg:       return "bad argument"
            case .notCapable:   return "pin cannot do that"
            case .busy:         return "pin is busy with a pulse"
            case .unauthorized: return "board rejected the owner key"
            case .wrongLink:    return "only allowed over Bluetooth"
            case .alreadyClaimed: return "board already belongs to another phone"
            case .scanning:     return "board is still scanning for networks"
            case .scriptError:  return "script error"
            }
        }
    }

    enum PinMode: UInt8, CaseIterable, Identifiable {
        case unset = 0, output, input, inputPullup, inputPulldown, pwm
        var id: UInt8 { rawValue }

        var label: String {
            switch self {
            case .unset:         return "Unset"
            case .output:        return "Output"
            case .input:         return "Input"
            case .inputPullup:   return "Input, pull-up"
            case .inputPulldown: return "Input, pull-down"
            case .pwm:           return "PWM"
            }
        }

        /// Name accepted from Jarvis in `esp32_set_pin_mode`.
        var wireName: String {
            switch self {
            case .unset:         return "unset"
            case .output:        return "output"
            case .input:         return "input"
            case .inputPullup:   return "input_pullup"
            case .inputPulldown: return "input_pulldown"
            case .pwm:           return "pwm"
            }
        }

        static func from(wireName: String) -> PinMode? {
            allCases.first { $0.wireName == wireName.lowercased() }
        }

        var isInput: Bool { self == .input || self == .inputPullup || self == .inputPulldown }
    }

    enum WifiState: UInt8 {
        case off = 0, connecting, connected, failed

        var label: String {
            switch self {
            case .off:        return "Not set up"
            case .connecting: return "Joining…"
            case .connected:  return "Connected"
            case .failed:     return "Failed, retrying"
            }
        }
    }

    enum ScriptState: UInt8 {
        case none = 0, stopped, running, finished, error

        var label: String {
            switch self {
            case .none:     return "No script"
            case .stopped:  return "Stopped"
            case .running:  return "Running"
            case .finished: return "Finished"
            case .error:    return "Error"
            }
        }
    }

    struct ScriptStatus: Hashable {
        let state: ScriptState
        let autostart: Bool
        let size: Int
        let name: String
        let error: String
    }

    struct PinCapabilities: OptionSet, Hashable {
        let rawValue: UInt8
        static let input     = PinCapabilities(rawValue: 1 << 0)
        static let output    = PinCapabilities(rawValue: 1 << 1)
        static let pwm       = PinCapabilities(rawValue: 1 << 2)
        static let strapping = PinCapabilities(rawValue: 1 << 3)
        static let led       = PinCapabilities(rawValue: 1 << 4)
    }

    struct PinInfo: Hashable, Identifiable {
        let gpio: UInt8
        let capabilities: PinCapabilities
        var id: UInt8 { gpio }
        var isInputOnly: Bool { !capabilities.contains(.output) }
    }

    struct PinState: Hashable {
        let gpio: UInt8
        var mode: PinMode
        /// Level (0/1) for digital modes, duty (0…255) for PWM.
        var value: UInt8
    }

    struct BoardInfo: Hashable {
        let protocolVersion: UInt8
        let firmwareMajor: UInt8
        let firmwareMinor: UInt8
        let uptimeSeconds: UInt32
        let mac: [UInt8]
        /// False on a freshly flashed board: the first phone to connect owns it.
        let claimed: Bool

        var macString: String { mac.map { String(format: "%02X", $0) }.joined(separator: ":") }
        /// Stable identity across transports and CoreBluetooth UUID rotations.
        var deviceID: String { "esp32-" + mac.map { String(format: "%02x", $0) }.joined() }
        var firmwareString: String { "\(firmwareMajor).\(firmwareMinor)" }
    }

    struct WifiNetwork: Hashable, Identifiable {
        let ssid: String
        let rssi: Int
        let secure: Bool
        var id: String { ssid }
    }

    struct WifiScanPage: Equatable {
        let total: Int
        let page: Int
        let networks: [WifiNetwork]
    }

    struct WifiStatus: Hashable {
        let state: WifiState
        let ip: String?
        let rssi: Int
        let port: UInt16
        let hostname: String
        let ssid: String
    }

    // MARK: - Framing

    static func crc8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    /// Builds a complete request frame. Returns nil if the payload is too long.
    static func encode(_ op: Op, payload: [UInt8] = []) -> [UInt8]? {
        let body = [op.rawValue] + payload
        guard body.count <= maxBody else { return nil }
        var frame: [UInt8] = [sync, UInt8(body.count)]
        frame += body
        frame.append(crc8(frame[1...]))
        return frame
    }

    enum Inbound: Equatable {
        /// A reply to one of our requests. `op` is the request opcode without bit 7.
        case response(op: UInt8, status: Status, payload: [UInt8])
        case event(Event, payload: [UInt8])
    }

    /// Validates framing and CRC. Nil on any structural problem or unknown event.
    static func decode(_ bytes: [UInt8]) -> Inbound? {
        guard bytes.count >= 4, bytes[0] == sync else { return nil }
        let bodyLen = Int(bytes[1])
        guard bodyLen >= 1, bodyLen <= maxBody, bytes.count == 2 + bodyLen + 1 else { return nil }
        guard crc8(bytes[1..<(bytes.count - 1)]) == bytes[bytes.count - 1] else { return nil }
        let op = bytes[2]
        let payload = Array(bytes[3..<(bytes.count - 1)])
        if op & responseBit != 0 && op < 0xE0 {
            guard let first = payload.first, let status = Status(rawValue: first) else { return nil }
            return .response(op: op & ~responseBit, status: status, payload: Array(payload.dropFirst()))
        }
        guard let event = Event(rawValue: op) else { return nil }
        return .event(event, payload: payload)
    }

    /// Reassembles frames out of a byte stream (the TCP side). Skips garbage between
    /// frames and drops anything that fails CRC.
    struct StreamParser {
        private var buffer: [UInt8] = []

        mutating func feed(_ data: Data) -> [Inbound] {
            var out: [Inbound] = []
            for b in data {
                if buffer.isEmpty {
                    if b == sync { buffer.append(b) }
                    continue
                }
                if buffer.count == 1 {
                    if b < 1 || Int(b) > maxBody { buffer.removeAll(); continue }
                    buffer.append(b)
                    continue
                }
                buffer.append(b)
                let expected = 2 + Int(buffer[1]) + 1
                if buffer.count == expected {
                    if let frame = decode(buffer) { out.append(frame) }
                    buffer.removeAll()
                }
            }
            return out
        }

        mutating func reset() { buffer.removeAll() }
    }

    // MARK: - Request builders

    static func wifiSetPayload(ssid: String, password: String) -> [UInt8]? {
        let s = Array(ssid.utf8), p = Array(password.utf8)
        guard !s.isEmpty, s.count <= maxSSIDLength, p.count <= maxPasswordLength else { return nil }
        return [UInt8(s.count)] + s + [UInt8(p.count)] + p
    }

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    /// Script uploads: BEGIN header, then CHUNKs of at most `scriptChunkSize` bytes.
    static let scriptChunkSize = 200
    static let maxScriptBytes = 16 * 1024

    static func scriptBeginPayload(total: Int, autostart: Bool, name: String) -> [UInt8]? {
        guard total > 0, total <= maxScriptBytes else { return nil }
        let n = Array(name.utf8.prefix(40))
        return u16(UInt16(total)) + [autostart ? 1 : 0, UInt8(n.count)] + n
    }

    static func lengthPrefixed(_ p: [UInt8], from cursor: inout Int) -> String? {
        guard cursor < p.count else { return nil }
        let n = Int(p[cursor]); cursor += 1
        guard cursor + n <= p.count else { return nil }
        defer { cursor += n }
        return String(decoding: p[cursor..<(cursor + n)], as: UTF8.self)
    }

    // MARK: - Response parsers

    static func parsePing(_ p: [UInt8]) -> BoardInfo? {
        guard p.count >= 13 else { return nil }
        let uptime = UInt32(p[3]) << 24 | UInt32(p[4]) << 16 | UInt32(p[5]) << 8 | UInt32(p[6])
        return BoardInfo(protocolVersion: p[0], firmwareMajor: p[1], firmwareMinor: p[2],
                         uptimeSeconds: uptime, mac: Array(p[7..<13]), claimed: p.count > 13 && p[13] != 0)
    }

    static func parseInfo(_ p: [UInt8]) -> [PinInfo]? {
        guard let count = p.first, p.count == 1 + Int(count) * 2 else { return nil }
        return (0..<Int(count)).map {
            PinInfo(gpio: p[1 + $0 * 2], capabilities: PinCapabilities(rawValue: p[2 + $0 * 2]))
        }
    }

    static func parseState(_ p: [UInt8]) -> [PinState]? {
        guard let count = p.first, p.count == 1 + Int(count) * 3 else { return nil }
        var out: [PinState] = []
        for i in 0..<Int(count) {
            let base = 1 + i * 3
            guard let mode = PinMode(rawValue: p[base + 1]) else { return nil }
            out.append(PinState(gpio: p[base], mode: mode, value: p[base + 2]))
        }
        return out
    }

    private static func ipString(_ bytes: ArraySlice<UInt8>) -> String? {
        bytes.allSatisfy { $0 == 0 } ? nil : bytes.map(String.init).joined(separator: ".")
    }

    static func parseWifiStatus(_ p: [UInt8]) -> WifiStatus? {
        // state, ip[4], rssi, port[2], host_len, host…, ssid_len, ssid…
        guard p.count >= 9, let state = WifiState(rawValue: p[0]) else { return nil }
        let rssi = Int(Int8(bitPattern: p[5]))
        let port = UInt16(p[6]) << 8 | UInt16(p[7])
        var cursor = 8
        func string() -> String? {
            guard cursor < p.count else { return nil }
            let n = Int(p[cursor]); cursor += 1
            guard cursor + n <= p.count else { return nil }
            defer { cursor += n }
            return String(decoding: p[cursor..<(cursor + n)], as: UTF8.self)
        }
        guard let host = string(), let ssid = string() else { return nil }
        return WifiStatus(state: state, ip: ipString(p[1...4]), rssi: rssi, port: port, hostname: host, ssid: ssid)
    }

    /// WIFI_SCAN response: total, page, count, (rssi, secure, ssid_len, ssid…)…
    static func parseWifiScan(_ p: [UInt8]) -> WifiScanPage? {
        guard p.count >= 3 else { return nil }
        var networks: [WifiNetwork] = []
        var cursor = 3
        for _ in 0..<Int(p[2]) {
            guard cursor + 3 <= p.count else { return nil }
            let rssi = Int(Int8(bitPattern: p[cursor]))
            let secure = p[cursor + 1] != 0
            let n = Int(p[cursor + 2])
            cursor += 3
            guard cursor + n <= p.count else { return nil }
            let ssid = String(decoding: p[cursor..<(cursor + n)], as: UTF8.self)
            cursor += n
            if !ssid.isEmpty { networks.append(WifiNetwork(ssid: ssid, rssi: rssi, secure: secure)) }
        }
        return WifiScanPage(total: Int(p[0]), page: Int(p[1]), networks: networks)
    }

    static func cloudSetPayload(server: String, code: String, cfID: String, cfSecret: String) -> [UInt8]? {
        var out: [UInt8] = []
        for part in [server, code, cfID, cfSecret] {
            let b = Array(part.utf8)
            guard b.count <= 120 else { return nil }
            out.append(UInt8(b.count)); out += b
        }
        return out.count + 1 <= maxBody ? out : nil
    }

    /// CLOUD_STATUS response: state, mode, url_len, url…, err_len, err…
    static func parseCloudStatus(_ p: [UInt8]) -> CloudStatus? {
        guard p.count >= 4, let state = CloudState(rawValue: p[0]) else { return nil }
        var cursor = 2
        guard let server = lengthPrefixed(p, from: &cursor), let error = lengthPrefixed(p, from: &cursor) else { return nil }
        return CloudStatus(state: state, cloudMode: p[1] != 0, server: server, error: error)
    }

    /// SCRIPT_STATUS response: state, autostart, size (u16), name_len, name…, err_len, err…
    static func parseScriptStatus(_ p: [UInt8]) -> ScriptStatus? {
        guard p.count >= 6, let state = ScriptState(rawValue: p[0]) else { return nil }
        var cursor = 4
        guard let name = lengthPrefixed(p, from: &cursor), let error = lengthPrefixed(p, from: &cursor) else { return nil }
        return ScriptStatus(state: state, autostart: p[1] != 0, size: Int(p[2]) << 8 | Int(p[3]), name: name, error: error)
    }

    /// `jarvis_call` event: call_id (u16), name_len, name…, json…
    static func parseJarvisCall(_ p: [UInt8]) -> (id: UInt16, name: String, json: String)? {
        guard p.count >= 4 else { return nil }
        var cursor = 2
        guard let name = lengthPrefixed(p, from: &cursor) else { return nil }
        return (UInt16(p[0]) << 8 | UInt16(p[1]), name, String(decoding: p[cursor...], as: UTF8.self))
    }

    /// `wifi_changed` event: state, ip[4].
    static func parseWifiChanged(_ p: [UInt8]) -> (WifiState, String?)? {
        guard p.count >= 5, let state = WifiState(rawValue: p[0]) else { return nil }
        return (state, ipString(p[1...4]))
    }
}

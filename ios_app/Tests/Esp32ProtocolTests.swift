import Foundation

/// Standalone check of the ESP32 codec, run the same way as the scale tests:
///   swiftc -parse-as-library JarvisCopilot/Esp32Protocol.swift Tests/Esp32ProtocolTests.swift -o /tmp/esp32tests && /tmp/esp32tests
@main
enum Esp32ProtocolTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        typealias P = Esp32Protocol

        // CRC-8 poly 0x07 known answer, same as the static_assert in Protocol.h.
        expect(P.crc8(Array("123456789".utf8)) == 0xF4, "CRC-8 known answer")
        expect(P.crc8([]) == 0, "empty CRC is zero")

        // A ping request is the smallest frame: A5 01 01 CRC.
        let ping = P.encode(.ping)!
        expect(ping.count == 4 && ping[0] == 0xA5 && ping[1] == 1 && ping[2] == 0x01, "ping framing")
        expect(ping[3] == P.crc8([0x01, 0x01]), "ping CRC covers LEN and OP")

        // Payload too long is refused rather than truncated.
        expect(P.encode(.wifiSet, payload: [UInt8](repeating: 0, count: 300)) == nil, "oversize refused")

        // Round-trip a synthetic ping response the way the firmware builds it.
        let mac: [UInt8] = [0xA4, 0xCF, 0x12, 0x34, 0x56, 0x78]
        var body: [UInt8] = [0x01 | 0x80, 0x00, 3, 1, 0, 0, 0, 0x01, 0x2C] + mac + [1]
        var frame: [UInt8] = [0xA5, UInt8(body.count)] + body
        frame.append(P.crc8(frame[1...]))
        guard case .response(let op, let status, let payload)? = P.decode(frame) else {
            fatalError("ping response must decode")
        }
        expect(op == 0x01 && status == .ok, "response op/status")
        let info = P.parsePing(payload)!
        expect(info.protocolVersion == 3 && info.firmwareMajor == 1 && info.uptimeSeconds == 300, "ping fields")
        expect(info.deviceID == "esp32-a4cf12345678", "device id from MAC")
        expect(info.claimed, "claimed flag")
        expect(P.parsePing(Array(payload.dropLast()))?.claimed == false, "missing claimed byte reads as unclaimed")

        // A flipped bit fails CRC and is dropped.
        var corrupt = frame; corrupt[5] ^= 0x01
        expect(P.decode(corrupt) == nil, "corrupt frame rejected")

        // Events carry no status byte.
        body = [0xE1, 4, 1]
        frame = [0xA5, UInt8(body.count)] + body
        frame.append(P.crc8(frame[1...]))
        expect(P.decode(frame) == .event(.inputChanged, payload: [4, 1]), "input event")

        // GET_INFO / GET_STATE parsers reject length mismatches.
        expect(P.parseInfo([2, 2, 0x1F, 4, 0x07]) != nil, "info parses")
        expect(P.parseInfo([2, 2, 0x1F]) == nil, "short info rejected")
        let state = P.parseState([1, 2, 1, 1])!
        expect(state[0].gpio == 2 && state[0].mode == .output && state[0].value == 1, "state parses")
        expect(P.parseState([1, 2, 9, 1]) == nil, "unknown mode rejected")

        // Wi‑Fi status with hostname and SSID.
        let host = Array("jarvis-esp32-5678".utf8), ssid = Array("Home".utf8)
        let wifi = P.parseWifiStatus([2, 192, 168, 1, 40, 0xC4, 0x12, 0x67, UInt8(host.count)] + host + [UInt8(ssid.count)] + ssid)!
        expect(wifi.state == .connected && wifi.ip == "192.168.1.40" && wifi.rssi == -60, "wifi status")
        expect(wifi.port == 4711 && wifi.hostname == "jarvis-esp32-5678" && wifi.ssid == "Home", "wifi strings")
        expect(P.parseWifiStatus([0, 0, 0, 0, 0, 0, 0x12, 0x67, 0, 0])?.ip == nil, "no ip when off")

        // The stream parser reassembles frames split across reads and skips junk.
        var parser = P.StreamParser()
        let two = frame + [0x00, 0x11] + ping  // event, junk, then a (request-shaped) ping
        let first = parser.feed(Data(two.prefix(3)))
        expect(first.isEmpty, "incomplete frame held back")
        let rest = parser.feed(Data(two.dropFirst(3)))
        expect(rest.count == 1 && rest[0] == .event(.inputChanged, payload: [4, 1]), "stream reassembly")

        // Wi‑Fi credential payload honours the firmware limits.
        expect(P.wifiSetPayload(ssid: "", password: "x") == nil, "empty ssid refused")
        expect(P.wifiSetPayload(ssid: String(repeating: "a", count: 33), password: "") == nil, "long ssid refused")
        expect(P.wifiSetPayload(ssid: "ab", password: "cd") == [2, 97, 98, 2, 99, 100], "wifi payload layout")

        // Wi‑Fi scan page: total 5, page 1, two entries.
        let a = Array("Home".utf8), b = Array("Cafe".utf8)
        let scan = P.parseWifiScan([5, 1, 2, 0xC4, 1, UInt8(a.count)] + a + [0xB0, 0, UInt8(b.count)] + b)!
        expect(scan.total == 5 && scan.page == 1 && scan.networks.count == 2, "scan page header")
        expect(scan.networks[0] == .init(ssid: "Home", rssi: -60, secure: true), "scan entry")
        expect(scan.networks[1] == .init(ssid: "Cafe", rssi: -80, secure: false), "open network entry")
        expect(P.parseWifiScan([5, 1, 2, 0xC4, 1, 9, 65]) == nil, "truncated scan rejected")

        // Script status and a jarvis_call event.
        let nm = Array("door".utf8), er = Array("boom".utf8)
        let st = P.parseScriptStatus([2, 1, 0x01, 0x2C, UInt8(nm.count)] + nm + [UInt8(er.count)] + er)!
        expect(st.state == .running && st.autostart && st.size == 300 && st.name == "door" && st.error == "boom", "script status")
        let call = P.parseJarvisCall([0x00, 0x07, 6] + Array("notify".utf8) + Array("{\"title\":\"Door\"}".utf8))!
        expect(call.id == 7 && call.name == "notify" && call.json == "{\"title\":\"Door\"}", "jarvis call")
        expect(P.scriptBeginPayload(total: 300, autostart: true, name: "door") == [0x01, 0x2C, 1, 4] + nm, "script begin payload")
        expect(P.scriptBeginPayload(total: 0, autostart: true, name: "x") == nil, "empty script refused")

        // Cloud status and the pairing payload.
        let srv = Array("https://j.example".utf8)
        let cs = P.parseCloudStatus([3, 1, UInt8(srv.count)] + srv + [0])!
        expect(cs.state == .connected && cs.cloudMode && cs.server == "https://j.example" && cs.error.isEmpty, "cloud status")
        expect(P.cloudSetPayload(server: "s", code: "ABC-123", cfID: "", cfSecret: "") == [1, 115, 7] + Array("ABC-123".utf8) + [0, 0], "cloud set payload")
        expect(P.cloudSetPayload(server: String(repeating: "x", count: 121), code: "", cfID: "", cfSecret: "") == nil, "long server refused")

        print("Esp32ProtocolTests passed")
    }
}

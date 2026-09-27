import Foundation
import SwiftUI

/// Explicit local opt-in gates source-derived controls that lack independent GO3 trials.
enum InmoAdvancedControls {
    static let languages = ["zh-CN", "zh-TW", "en-US", "ja-JP", "ko-KR", "es-ES", "pt-BR", "fr-FR", "de-DE", "it-IT", "th-TH", "zh-HK", "ru-RU", "ar-SA", "sv-SE", "es-MX", "cs-CZ", "tr-TR", "pl-PL", "pt-PT", "ms-MY", "fil-PH", "id-ID"]
    static var capabilities: [DeviceCapability] {
        [DeviceCapability(name: "glasses_device_setting", description: "Experimental device name, language or phone time synchronization. Requires local experimental opt-in.", inputSchema: DeviceCapability.schema(["setting": ["type": "string", "enum": ["name", "language", "sync_time"]], "value": ["type": "string", "maxLength": 64]], required: ["setting"])),
         DeviceCapability(name: "glasses_remote_key", description: "Experimental source-derived GO, menu, long Home or double tap; behaviors are not device-verified.", inputSchema: DeviceCapability.schema(["key": ["type": "string", "enum": ["go", "menu", "long_home", "double_tap"]]], required: ["key"]))]
    }
    static func setting(_ name: String, value: String?, date: Date = Date(), zone: TimeZone = .current) throws -> Data {
        let type: UInt64, field: Int, payload: Data
        switch name {
        case "name":
            guard let value, !value.isEmpty, value.utf8.count <= 64, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { throw DeviceError.badArgument("name requires 1–64 UTF-8 bytes without control characters") }
            type = 7; field = 3; payload = InmoWireCodec.string(1, value)
        case "language":
            guard let value, let index = languages.firstIndex(of: value) else { throw DeviceError.badArgument("Use a supported locale such as en-US") }
            type = 11; field = 7; payload = InmoWireCodec.uint(1, UInt64(index))
        case "sync_time":
            // Matches sendSystemTime and h0.d(): epoch milliseconds, signed whole hours.
            type = 12; field = 8
            let milliseconds = date.timeIntervalSince1970 * 1000
            guard milliseconds >= 0, milliseconds < Double(Int64.max) else { throw DeviceError.badArgument("Invalid system time") }
            payload = InmoWireCodec.uint(4, UInt64(milliseconds)) + InmoWireCodec.signed(5, Int64(zone.secondsFromGMT(for: date) / 3600))
        default: throw DeviceError.badArgument("Unsupported device setting")
        }
        return InmoCommand.envelope(type: 19, field: 22, payload: InmoWireCodec.uint(1, type) + InmoWireCodec.bytes(field, payload), version: 1)
    }
    static func remoteKey(_ key: String) throws -> Data {
        switch key {
        case "go": return InmoCommand.control(7)
        case "menu": return InmoCommand.control(6)
        case "long_home": return InmoCommand.control(26)
        case "double_tap": return InmoCommand.control(8, field: 8, payload: InmoWireCodec.uint(1, 3) + InmoWireCodec.uint(3, 50) + InmoWireCodec.uint(4, 50))
        default: throw DeviceError.badArgument("Unsupported remote key")
        }
    }
    @MainActor static func install(on device: InmoGo3Device) {
        for name in ["glasses_device_setting", "glasses_remote_key"] {
            device.featureHandlers[name] = { [weak device] args in
                guard let device, device.experimentalEnabled else { throw DeviceError.badArgument("Enable experimental controls locally first") }
                let data: Data
                if name == "glasses_device_setting" {
                    guard let settingName = args["setting"] as? String else { throw DeviceError.badArgument("setting is required") }
                    data = try setting(settingName, value: args["value"] as? String)
                } else {
                    guard let key = args["key"] as? String else { throw DeviceError.badArgument("key is required") }
                    data = try remoteKey(key)
                }
                try await device.session.send(data)
                return ["state": "sent", "confirmed": false, "evidence": "source-derived; independent hardware trial pending"]
            }
        }
    }
}

struct InmoAdvancedControlsView: View {
    @ObservedObject private var device = InmoGo3Device.shared
    @State private var name = ""
    @State private var language = "en-US"
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Additional device controls").font(.subheadline.bold())
            TextField("Name on glasses", text: $name)
            Button("Set Device Name") { run("glasses_device_setting", ["setting": "name", "value": name]) }.disabled(name.isEmpty)
            Picker("System language", selection: $language) { ForEach(InmoAdvancedControls.languages, id: \.self) { Text($0).tag($0) } }
            Button("Set Language") { run("glasses_device_setting", ["setting": "language", "value": language]) }
            Button("Sync Phone Time") { run("glasses_device_setting", ["setting": "sync_time"]) }
            Text("Time synchronization follows the vendor's whole-hour timezone offset; fractional-hour zones lose their minutes.").font(.caption).foregroundStyle(.secondary)
            HStack { ForEach(["go", "menu", "long_home", "double_tap"], id: \.self) { key in
                Button(key.replacingOccurrences(of: "_", with: " ").capitalized) { run("glasses_remote_key", ["key": key]) }
            } }
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
        }.disabled(!device.experimentalEnabled || !device.isConnected)
    }
    private func run(_ skill: String, _ args: [String: Any]) {
        Task { do { _ = try await device.invoke(skill, args: args); result = "Sent; device confirmation pending." } catch { result = error.localizedDescription } }
    }
}

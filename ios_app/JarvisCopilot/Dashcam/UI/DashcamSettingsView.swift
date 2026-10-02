import SwiftUI

/// Camera settings (read from the camera's own list — only while on its Wi‑Fi), the SD card,
/// the clock and Wi‑Fi, and the phone's sync rules.
struct DashcamSettingsView: View {
    @ObservedObject private var sync: DashcamSync = .shared
    @ObservedObject private var wifi: DashcamWiFi = .shared
    @State private var items: [DashcamSettingItem] = []
    @State private var loading = false
    @State private var note: String?
    @State private var confirmFormat = false
    @State private var confirmForget = false
    @State private var newSSID = ""
    @State private var newPassword = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            if let note {
                Text(note).font(.footnote).foregroundStyle(JcTheme.amber).padding(.horizontal, 20)
            }
            rules
            if wifi.onCamera { cameraSettings; card; wifiSection } else {
                CardGroup("Camera") {
                    CardEmptyBlock("Camera settings show up while the phone is on the dashcam's Wi‑Fi (start the car).", symbol: "wifi.slash")
                }
            }
            CardGroup {
                Row {
                    Button(role: .destructive) { confirmForget = true } label: { Text("Forget this dashcam") }
                }
            }
        }
        .task(id: wifi.onCamera) { if wifi.onCamera { await loadSettings() } }
        .alert("Format the SD card?", isPresented: $confirmFormat) {
            Button("Format", role: .destructive) { Task { await run("dashcam_format_sd", ["confirm": true], done: "SD card formatted.") } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every clip on the card is erased, including locked events that haven't been uploaded.") }
        .alert("Forget this dashcam?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { forget() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The phone stops joining its Wi‑Fi. Uploaded clips and drives stay on the server.") }
    }

    // MARK: Sync rules (stored on the server)

    private var rules: some View {
        CardGroup("Sync rules", footer: "Events, parking clips and photos are always pulled. Normal footage is 15–20 GB an hour at 4K, so it follows these rules.") {
            Row {
                Picker("Normal footage", selection: ruleBinding(\.normal)) {
                    ForEach(DashcamRules.Normal.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            RowDivider()
            Row {
                Picker("When", selection: ruleBinding(\.normalWhen)) {
                    ForEach(DashcamRules.When.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            RowDivider()
            Row {
                Stepper("Phone space: \(sync.rules.phoneCapGB) GB", value: ruleBinding(\.phoneCapGB), in: 1...512, step: 5)
            }
            RowDivider()
            Row { Toggle("Keep clips on the phone after upload", isOn: ruleBinding(\.keepOnPhone)).tint(JcTheme.accent) }
        }
    }

    private func ruleBinding<T>(_ key: WritableKeyPath<DashcamRules, T>) -> Binding<T> {
        Binding(get: { sync.rules[keyPath: key] }, set: { value in
            sync.rules[keyPath: key] = value
            let rules = sync.rules
            Task {
                do { try await DashcamAPI().updateRules(rules) } catch { note = "Couldn't save the rules: \(error.localizedDescription)" }
            }
        })
    }

    // MARK: Camera

    private var cameraSettings: some View {
        CardGroup("Camera settings") {
            if loading && items.isEmpty { Row { ProgressView() } }
            ForEach(Array(items.filter { !$0.options.isEmpty }.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider() }
                Row {
                    Picker(Self.title(item.name), selection: Binding(get: { item.value ?? "" }, set: { new in
                        Task { await set(item, new) }
                    })) {
                        ForEach(item.options, id: \.code) { Text($0.label).tag($0.code) }
                    }
                }
            }
        }
    }

    private var card: some View {
        CardGroup("SD card & clock") {
            Row {
                HStack {
                    Text("Free").foregroundStyle(.secondary)
                    Spacer()
                    if let sd = sync.sd, let free = sd.freeBytes, let total = sd.totalBytes {
                        Text(String(format: "%.1f of %.1f GB", Double(free) / 1e9, Double(total) / 1e9))
                    } else {
                        Text(sync.sd?.ok == false ? "No card" : "–")
                    }
                }
            }
            RowDivider()
            Row { Button("Sync the camera's clock now") { Task { await sync.syncNow(); note = "Clock set from the phone." } } }
            RowDivider()
            Row { Button("Format the SD card…", role: .destructive) { confirmFormat = true } }
        }
    }

    private var wifiSection: some View {
        CardGroup("Camera Wi‑Fi", footer: "The camera restarts its Wi‑Fi after a change; the phone saves the new network and rejoins on its own.") {
            Row { TextField("New name (\(DashcamSetupStore.load()?.ssid ?? ""))", text: $newSSID).textInputAutocapitalization(.never) }
            RowDivider()
            Row { SecureField("New password (8+ characters)", text: $newPassword) }
            RowDivider()
            Row {
                Button("Change Wi‑Fi") {
                    var args: [String: Any] = [:]
                    if !newSSID.isEmpty { args["ssid"] = newSSID }
                    if !newPassword.isEmpty { args["password"] = newPassword }
                    Task { await run("dashcam_set_wifi", args, done: "Wi‑Fi changed.") }
                }
                .disabled(newSSID.isEmpty && newPassword.isEmpty)
            }
        }
    }

    static func title(_ key: String) -> String {
        let known = ["rec_resolution": "Resolution", "rec_split_duration": "Clip length", "gsr_sensitivity": "G‑sensor",
                     "park_gsr_sensitivity": "Parking G‑sensor", "parking_monitor": "Parking monitor", "parking_mode": "Parking mode",
                     "mic": "Microphone", "speed_unit": "Speed unit", "osd": "Date & speed stamp", "wdr": "WDR", "ev": "Exposure",
                     "speaker": "Volume", "voice_control": "Voice control", "boot_sound": "Start-up sound", "key_tone": "Key tone",
                     "light_fre": "Light frequency", "screen_standby": "Screen saver", "auto_poweroff": "Auto power off",
                     "low_power_protect": "Low-voltage cut-off", "timelapse_rate": "Time-lapse rate", "park_record_time": "Parking recording",
                     "encodec": "Video codec", "language": "Language", "rear_mirror": "Mirror rear camera", "video_flip": "Flip video",
                     "video_mirror": "Mirror video", "low_fps_record": "Time-lapse parking", "adas": "Driver assist alerts"]
        return known[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func loadSettings() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await DashcamDevice.shared.invoke("dashcam_get_settings", args: [:])
            items = (result["settings"] as? [[String: Any]] ?? []).compactMap { row in
                guard let key = row["key"] as? String else { return nil }
                let options = (row["options"] as? [[String: Any]] ?? []).compactMap { o -> DashcamSettingItem.Option? in
                    guard let c = o["code"] as? String, let l = o["label"] as? String else { return nil }
                    return .init(code: c, label: l)
                }
                return DashcamSettingItem(name: key, value: row["value"] as? String, options: options, range: row["range"] as? String)
            }
        } catch {
            note = error.localizedDescription
        }
    }

    private func set(_ item: DashcamSettingItem, _ code: String) async {
        await run("dashcam_set_setting", ["key": item.name, "value": code], done: "\(Self.title(item.name)) changed.")
        await loadSettings()
    }

    private func run(_ skill: String, _ args: [String: Any], done: String) async {
        do {
            _ = try await DashcamDevice.shared.invoke(skill, args: args)
            note = done
        } catch {
            note = error.localizedDescription
        }
    }

    private func forget() {
        if let setup = DashcamSetupStore.load() { DashcamWiFi.shared.forget(ssid: setup.ssid) }
        DashcamSetupStore.save(nil)
        DashcamSetupStore.password = nil
        DashcamDevice.shared.refreshMembership()
        DashcamSync.shared.cameraChanged(false)
        dismiss()
    }
}

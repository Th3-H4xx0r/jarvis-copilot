import SwiftUI

/// The camera's own buttons, from the phone: live view, record, photo, lock the current clip, mic.
/// Each runs through the same `dashcam_*` skills the agent uses. Only shown on the camera's Wi‑Fi.
struct DashcamControlsCard: View {
    @ObservedObject private var sync: DashcamSync = .shared
    @Binding var live: Bool
    @State private var mic: Bool?
    @State private var micCodes = (on: "1", off: "0")
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        CardGroup("Controls", footer: note) {
            Row {
                HStack(spacing: 0) {
                    control("Live", "video", tint: JcTheme.accent) { live = true }
                    control(sync.recording == false ? "Record" : "Stop", sync.recording == false ? "record.circle" : "stop.circle",
                            tint: sync.recording == false ? JcTheme.accent : JcTheme.danger, id: "rec") { await toggleRecording() }
                    control("Photo", "camera", tint: JcTheme.accent, id: "photo") { await photo() }
                    control("Lock clip", "lock", tint: JcTheme.amber, id: "lock") { await lock() }
                    if let mic {
                        control(mic ? "Mic on" : "Mic off", mic ? "mic" : "mic.slash", tint: mic ? JcTheme.accent : JcTheme.muted,
                                id: "mic") { await setMic(!mic) }
                    }
                }
            }
        }
        .task { await loadMic() }
    }

    private func control(_ title: String, _ icon: String, tint: Color, id: String? = nil,
                         action: @escaping () async -> Void) -> some View {
        Button {
            guard busy == nil else { return }
            busy = id
            Task { await action(); busy = nil }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 48, height: 48)
                    if busy != nil && busy == id { ProgressView() } else { JcIcon(icon, size: 20).foregroundStyle(tint) }
                }
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel(title)
    }

    private func run(_ skill: String, _ args: [String: Any] = [:]) async -> [String: Any]? {
        do { return try await DashcamDevice.shared.invoke(skill, args: args) }
        catch { note = error.localizedDescription; return nil }
    }

    private func toggleRecording() async {
        let on = sync.recording == false
        guard let out = await run("dashcam_set_recording", ["enabled": on]) else { return }
        let now = out["recording"] as? Bool ?? on
        sync.noteRecording(now)
        note = now ? "Recording." : "Recording stopped — it stays off until you start it again."
    }

    private func photo() async {
        guard await run("dashcam_snapshot") != nil else { return }
        note = "Photo taken. It comes down with the next sync."
    }

    private func lock() async {
        guard await run("dashcam_lock_clip") != nil else { return }
        note = "This clip is locked as an event, so the camera won't record over it. It's pulled first."
    }

    private func loadMic() async {
        guard let out = try? await DashcamDevice.shared.invoke("dashcam_get_settings", args: [:]),
              let row = (out["settings"] as? [[String: Any]])?.first(where: { $0["key"] as? String == "mic" }) else { return }
        // The camera's own codes for on/off (usually "1"/"0").
        for option in row["options"] as? [[String: Any]] ?? [] {
            guard let code = option["code"] as? String else { continue }
            switch Self.isOn(option["label"]) ?? Self.isOn(code) {
            case true?: micCodes.on = code
            case false?: micCodes.off = code
            case nil: break
            }
        }
        mic = Self.isOn(row["label"]) ?? Self.isOn(row["value"])
    }

    private func setMic(_ on: Bool) async {
        guard await run("dashcam_set_setting", ["key": "mic", "value": on ? micCodes.on : micCodes.off]) != nil else { return }
        mic = on
        note = on ? "The camera records sound again." : "The camera records without sound."
    }

    static func isOn(_ value: Any?) -> Bool? {
        switch value {
        case let s as String: return ["1", "on", "true"].contains(s.lowercased()) ? true : ["0", "off", "false"].contains(s.lowercased()) ? false : nil
        case let n as NSNumber: return n.intValue != 0
        default: return nil
        }
    }
}

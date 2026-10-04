import SwiftUI

/// The camera's own buttons, from the phone: live view, record, photo, lock the current clip, mic.
/// Each runs through the same `dashcam_*` skills the agent uses. Only shown on the camera's Wi‑Fi.
struct DashcamControlsCard: View {
    @ObservedObject private var sync: DashcamSync = .shared
    @Binding var live: Bool
    @State private var mic: DashcamMic?
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
                        control(mic.on ? "Mic on" : "Mic off", mic.on ? "mic" : "mic.slash", tint: mic.on ? JcTheme.accent : JcTheme.muted,
                                id: "mic") { await setMic(!mic.on) }
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

    private func toggleRecording() async { note = await DashcamControls.toggleRecording() }

    private func photo() async { note = await DashcamControls.photo() }

    private func lock() async { note = await DashcamControls.lock() }

    private func loadMic() async { mic = await DashcamControls.mic() }

    private func setMic(_ on: Bool) async {
        guard let current = mic else { return }
        let result = await DashcamControls.setMic(on, current)
        note = result.note
        if result.ok { mic?.on = on }
    }
}

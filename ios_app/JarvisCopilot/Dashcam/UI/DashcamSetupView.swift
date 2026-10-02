import SwiftUI

/// First-time setup: the camera's Wi‑Fi name and password. The network is saved so iOS joins it
/// on its own from then on; the camera is found on it and remembered.
struct DashcamSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    JcIcon("video.fill", size: 44, weight: .light).foregroundStyle(JcTheme.accent)
                    Text("Add your dashcam").font(.title2.weight(.semibold))
                    Text("Turn the camera on (start the car), then enter the Wi‑Fi name and password shown in its Wi‑Fi menu. The iPhone will join it on its own whenever the camera is on.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 12)
                .padding(.horizontal, 24)

                CardGroup("Camera Wi‑Fi", footer: "Novatek cameras often use 1234567890; Viidure cameras usually show theirs on screen.") {
                    Row { TextField("Wi‑Fi name (e.g. Affver_A4_xxxx)", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    RowDivider()
                    Row { SecureField("Password", text: $password) }
                }

                if let message {
                    Text(message).font(.footnote).foregroundStyle(done ? JcTheme.success : JcTheme.amber)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "Looking for the camera…" : "Join and find the camera")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.jcGlass)
                .disabled(busy || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 30)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Dashcam")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if ssid.isEmpty, let current = DashcamWiFi.shared.currentSSID { ssid = current }
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        let name = ssid.trimmingCharacters(in: .whitespaces)
        do {
            if DashcamSetupStore.debugHost() == nil {
                try await DashcamWiFi.shared.save(ssid: name, password: password.isEmpty ? nil : password)
                try? await Task.sleep(for: .seconds(2))   // DHCP on the camera's network
            }
            var found: (family: DashcamFamily, base: URL)?
            for _ in 0..<4 where found == nil {
                found = await DashcamDetect.probe(host: DashcamSetupStore.debugHost())
                if found == nil { try? await Task.sleep(for: .seconds(2)) }
            }
            guard let found else {
                message = "Joined \(name), but no dashcam answered. Is the camera on and its Wi‑Fi enabled?"
                return
            }
            guard found.family.supported, let cam = DashcamDetect.camera(family: found.family, base: found.base) else {
                message = "Found a \(found.family.rawValue) camera — that family isn't supported yet. Run the probe from the Mac (dashcam_camera.py probe) and send the result."
                return
            }
            let info = try await cam.info()
            let host = found.base.host.map { h in found.base.port.map { "\(h):\($0)" } ?? h }
            let standard = DashcamDetect.candidates.first { $0.family == found.family }?.host
            let setup = DashcamSetup(ssid: name, family: found.family, cameraID: info.id, model: info.model,
                                     brand: info.brand, firmware: info.firmware, lenses: info.lenses,
                                     host: host == standard ? nil : host)
            DashcamSetupStore.password = password.isEmpty ? nil : password
            DashcamSetupStore.save(setup)
            DashcamDevice.shared.refreshMembership()
            DashcamSync.shared.start()
            await DashcamWiFi.shared.refresh()
            try? await DashcamAPI().upsertCamera(info, ssid: name)
            done = true
            message = "\(setup.displayName) is set up. Syncing now — events and photos come first."
            Task { await DashcamSync.shared.syncNow() }
        } catch {
            message = error.localizedDescription
        }
    }
}

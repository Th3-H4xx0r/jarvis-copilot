import NetworkExtension
import SwiftUI

/// First-time setup. iOS doesn't let apps list nearby Wi‑Fi, so there are three ways in:
/// - the screen keeps checking the iPhone's current Wi‑Fi and shows the camera the moment it's on
///   its network (join it in Settings → Wi‑Fi and come back);
/// - "Find nearby dashcams" opens Apple's accessory picker, which keeps scanning for dashcam-named
///   networks;
/// - pick or type the name in the Wi‑Fi dropdown.
/// The network is then saved so iOS rejoins it on its own whenever the camera is on.
struct DashcamSetupView: View {
    struct Detected: Equatable {
        let ssid: String?
        let family: DashcamFamily
        let base: URL
        let info: DashcamCameraInfo?
    }

    @State private var ssid = ""
    @State private var typing = false
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var done = false
    @State private var detected: Detected?
    @State private var currentSSID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    JcIcon("video.fill", size: 44, weight: .light).foregroundStyle(JcTheme.accent)
                    Text("Add your dashcam").font(.title2.weight(.semibold))
                    Text("Turn the camera on (start the car). Jarvis finds it on its Wi‑Fi, then joins it on its own whenever the camera is on.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 12)
                .padding(.horizontal, 24)

                liveCard
                pickerButton
                manualCard

                if let message {
                    Text(message).font(.footnote).foregroundStyle(done ? JcTheme.success : JcTheme.amber)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 30)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Dashcam")
        .navigationBarTitleDisplayMode(.inline)
        .task { await watch() }
    }

    // MARK: Live detection

    private var liveCard: some View {
        CardGroup("On this iPhone's Wi‑Fi", footer: detected == nil
                  ? "Or join the camera's Wi‑Fi in Settings → Wi‑Fi and come back — it shows up here by itself."
                  : nil) {
            Row {
                if let d = detected {
                    HStack(spacing: 12) {
                        JcIcon("checkmark.circle.fill", size: 22).foregroundStyle(JcTheme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Found \(Self.name(d.info))").font(.body.weight(.semibold))
                            Text(d.ssid.map { "on “\($0)”" } ?? d.family.rawValue.capitalized + " camera")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(d.family.supported ? "Use it" : "Not supported") {
                            Task { await finish(found: (d.family, d.base), ssid: d.ssid ?? ssid) }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(busy || !d.family.supported)
                    }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(currentSSID.map { "Checking “\($0)” for a dashcam…" } ?? "Looking for a dashcam…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Keeps checking while the screen is open: the iPhone's current network, and whether any
    /// dashcam family answers on it (all at once, so a round is one short timeout).
    private func watch() async {
        while !Task.isCancelled {
            if !busy {
                let name = DashcamSetupStore.debugHost() == nil ? await NEHotspotNetwork.fetchCurrent()?.ssid : "Fake camera"
                currentSSID = name
                if ssid.isEmpty, let name { ssid = name }
                if let hit = await DashcamDetect.probeAll(host: DashcamSetupStore.debugHost(), timeout: 1.5) {
                    var info: DashcamCameraInfo?
                    if detected?.base != hit.base || detected?.info == nil {
                        info = try? await DashcamDetect.camera(family: hit.family, base: hit.base)?.info()
                    } else {
                        info = detected?.info
                    }
                    detected = Detected(ssid: name, family: hit.family, base: hit.base, info: info)
                } else {
                    detected = nil
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: Apple's accessory picker

    @ViewBuilder private var pickerButton: some View {
        if #available(iOS 18.0, *) {
            Button {
                Task {
                    if let picked = await DashcamAccessoryPicker().pick() {
                        ssid = picked
                        typing = false
                        message = "Selected “\(picked)”. Enter its password (if it has one) and join."
                    }
                }
            } label: {
                Label("Find nearby dashcams", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.jcGlass)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Pick or type the network

    private var choices: [String] {
        var out: [String] = []
        if let currentSSID { out.append(currentSSID) }
        out += DashcamKnownNetworks.ssids().filter { $0 != currentSSID }
        return out
    }

    private var manualCard: some View {
        VStack(spacing: 14) {
            CardGroup("Camera Wi‑Fi", footer: "Viidure cameras usually show their Wi‑Fi name and password on screen; Novatek ones often use 1234567890.") {
                Row {
                    if typing {
                        HStack {
                            TextField("Wi‑Fi name", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { typing = false } label: { JcIcon("list.bullet", size: 15) }.buttonStyle(.plain)
                        }
                    } else {
                        Menu {
                            ForEach(choices, id: \.self) { name in
                                Button(name == currentSSID ? "\(name) (current)" : name) { ssid = name }
                            }
                            Divider()
                            Button("Enter a name…") { typing = true; ssid = "" }
                        } label: {
                            HStack {
                                Text(ssid.isEmpty ? "Choose the camera's Wi‑Fi" : ssid)
                                    .foregroundStyle(ssid.isEmpty ? .secondary : .primary)
                                Spacer()
                                JcIcon("chevron.up.chevron.down", size: 13).foregroundStyle(.secondary)
                            }
                        }
                        .tint(JcTheme.accent)
                    }
                }
                RowDivider()
                Row { SecureField("Password", text: $password) }
            }
            Button {
                Task { await join() }
            } label: {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Joining and looking for the camera…" : "Join and find the camera")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.jcGlass)
            .disabled(busy || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 20)
        }
    }

    private func join() async {
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
                found = await DashcamDetect.probeAll(host: DashcamSetupStore.debugHost())
                if found == nil { try? await Task.sleep(for: .seconds(2)) }
            }
            guard let found else {
                message = "Joined “\(name)”, but no dashcam answered. Is the camera on and its Wi‑Fi enabled?"
                return
            }
            await finish(found: found, ssid: name)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Remembers the camera and starts syncing (shared by every way in).
    private func finish(found: (family: DashcamFamily, base: URL), ssid name: String) async {
        busy = true
        defer { busy = false }
        guard found.family.supported, let cam = DashcamDetect.camera(family: found.family, base: found.base) else {
            message = "Found a \(found.family.rawValue) camera — that family isn't supported yet. Run the probe from the Mac (dashcam_camera.py probe) and send the result."
            return
        }
        do {
            let info = try await cam.info()
            let host = found.base.host.map { h in found.base.port.map { "\(h):\($0)" } ?? h }
            let standard = DashcamDetect.candidates.first { $0.family == found.family }?.host
            let setup = DashcamSetup(ssid: name, family: found.family, cameraID: info.id, model: info.model,
                                     brand: info.brand, firmware: info.firmware, lenses: info.lenses,
                                     host: host == standard ? nil : host)
            if !password.isEmpty { DashcamSetupStore.password = password }
            DashcamSetupStore.save(setup)
            DashcamKnownNetworks.learn(ssid: name)
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

    static func name(_ info: DashcamCameraInfo?) -> String {
        guard let info else { return "a dashcam" }
        let n = [info.brand, info.model].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? "a dashcam" : n
    }
}

import SwiftUI

/// The Game Streaming setup page: one smart screen shown as the integration's Settings
/// section. It auto-detects Sunshine on the gaming PC (jc-client reaches it at localhost,
/// so there is no host or port to type), takes the one manual input — the Sunshine
/// username + password — and lists the devices Sunshine is paired with, each with a type
/// control pre-guessed from its name and editable. Android TV rows take an adb address.
/// Black and white: only the single Save is filled; removing a device is the grey button
/// with a red label. No JSON anywhere.
struct GameStreamingSetupView: View {
    let row: PowerRow
    @State private var store = GameStreamingSetupStore(afterSave: {
        await GameStreamingStore.shared.refresh(fresh: true)
    })
    @State private var power: PowerState
    @State private var pairing = false
    @State private var feedback: GameActionResult?
    @State private var busy = false
    @State private var showHelp = false

    init(row: PowerRow, power: PowerState = .shared) {
        self.row = row
        _power = State(initialValue: power)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sunshineSection
            devicesSection
            feedbackLine
            GradientButton("Save", busy: busy, full: true, action: save)
                .padding(.top, 16)
        }
        .onAppear { store.seed(from: row) }
        // Fresh on appear and while on screen (5 s until Sunshine is found, then 15 s).
        .task { await store.keepFresh() }
        .onReceive(NotificationCenter.default.publisher(for: .gameStreamingRefresh)) { _ in
            Task { await store.refresh(fresh: true) }
        }
        .sheet(isPresented: $pairing) {
            GameStreamingPinSheet(store: .shared) { message in
                feedback = .ok(message)
                Task { await store.refresh(fresh: true) }     // the new device joins the list
            }
        }
    }

    // MARK: Sunshine

    @ViewBuilder
    private var sunshineSection: some View {
        JcSectionLabel("Sunshine", first: true)
        JcCard {
            VStack(alignment: .leading, spacing: 14) {
                statusRow
                Divider().overlay(JcTheme.border)
                loginFields
            }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if store.detect?.found == true {
                    JcIcon("checkmark", size: 12).foregroundStyle(JcTheme.text)
                } else {
                    Circle().fill(JcTheme.muted).frame(width: 7, height: 7)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            .accessibilityHidden(true)       // decorative; the headline carries the meaning
            VStack(alignment: .leading, spacing: 3) {
                Text(store.detectHeadline)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if store.detect?.found == true {
                    Text("No address or port to enter — your login is the only step")
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var loginFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Username",
                  text: Binding(get: { store.user }, set: { store.user = $0 }),
                  placeholder: "Your Sunshine username")
            Divider().overlay(JcTheme.border)
            VStack(alignment: .leading, spacing: 6) {
                Text("Password").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                SecureField(store.passwordPlaceholder,
                            text: Binding(get: { store.password }, set: { store.password = $0 }))
                    .font(.system(size: 16))
                    .foregroundStyle(JcTheme.text)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            }
            Button { withAnimation(.easeInOut(duration: 0.15)) { showHelp.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("Where do I find this?").font(.system(size: 12.5)).foregroundStyle(JcTheme.muted)
                    JcIcon(showHelp ? "chevron.up" : "chevron.down", size: 10).foregroundStyle(JcTheme.muted)
                }
            }
            .buttonStyle(.plain)
            if showHelp {
                Text("Open Sunshine's web UI on your PC (it opens at https://localhost:47990). It's the username and password you set there the first time you opened Sunshine.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 16))
                .foregroundStyle(JcTheme.text)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    // MARK: Devices

    @ViewBuilder
    private var devicesSection: some View {
        JcSectionLabel("Your devices")
        JcCard(padding: 0) {
            if store.devices.isEmpty {
                JcRow(symbol: "display", title: "No devices yet",
                      subtitle: store.detect == nil ? "Reading Sunshine…" : "Pair one below to add it",
                      last: false) { EmptyView() }
            } else {
                ForEach(store.devices) { device in
                    JcRow(symbol: symbol(for: device.kind), title: device.name,
                          subtitle: nil, last: false) {
                        typeMenu(device)
                    }
                    if device.kind == "androidtv" {
                        JcRow(symbol: "network", title: "Address",
                              subtitle: "Its IP address on your network", last: false) {
                            addressField(device)
                        }
                    }
                }
            }
            JcRow(symbol: "plus", title: "Add a device",
                  subtitle: "Pair a new Moonlight device with a PIN", last: true,
                  action: { pairing = true })
        }
    }

    private func typeMenu(_ device: GameDeviceDraft) -> some View {
        Menu {
            ForEach(GameDeviceDraft.kinds, id: \.value) { opt in
                Button { store.setKind(opt.value, for: device.id) } label: {
                    if opt.value == device.kind {
                        Label(opt.label, systemImage: "checkmark")
                    } else {
                        Text(opt.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label(for: device.kind)).font(.system(size: 15)).foregroundStyle(JcTheme.text)
                JcIcon("chevron.up.chevron.down", size: 11).foregroundStyle(JcTheme.muted)
            }
        }
    }

    private func addressField(_ device: GameDeviceDraft) -> some View {
        TextField("10.0.0.5:5555", text: Binding(
            get: { device.tvAddr },
            set: { store.setAddr($0, for: device.id) }))
            .font(.system(size: 15))
            .foregroundStyle(JcTheme.text)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numbersAndPunctuation)
            .frame(maxWidth: 160)
    }

    // MARK: Feedback

    @ViewBuilder
    private var feedbackLine: some View {
        switch feedback {
        case .failed(let message):
            IntegrationUIErrorLine(text: message).padding(.top, 12)
        case .ok(let note):
            Text(note ?? "Saved")
                .font(.system(size: 12.5))
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 12)
        case .none:
            EmptyView()
        }
    }

    // MARK: Helpers

    private func symbol(for kind: String) -> String {
        switch kind {
        case "mac": return "laptopcomputer"
        case "androidtv": return "tv"
        case "ios": return "iphone"
        default: return "display"
        }
    }

    private func label(for kind: String) -> String {
        GameDeviceDraft.kinds.first { $0.value == kind }?.label ?? "Mac"
    }

    private func save() {
        busy = true
        feedback = nil
        Task {
            let result = await store.save(row: row, power: power)
            busy = false
            feedback = result
        }
    }
}

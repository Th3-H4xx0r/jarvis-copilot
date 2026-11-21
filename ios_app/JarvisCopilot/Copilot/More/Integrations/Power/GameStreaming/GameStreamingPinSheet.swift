import SwiftUI

/// Pair a Moonlight device: it shows a PIN, you give Jarvis a name for it and the
/// PIN, and the host submits it (`POST /api/game-streaming/pair`). The PC must be
/// awake; a 409 says so. The one commit here is the main (filled) button — the
/// rest of the sheet is quiet.
struct GameStreamingPinSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: GameStreamingStore
    var onResult: (String) -> Void

    @State private var device = ""
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?

    private var canPair: Bool {
        !device.trimmingCharacters(in: .whitespaces).isEmpty &&
        pin.trimmingCharacters(in: .whitespaces).count >= 4
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    JcSectionLabel("Device", first: true)
                    JcCard {
                        VStack(alignment: .leading, spacing: 12) {
                            field("Name", text: $device, placeholder: "Living Room TV", keyboard: .default)
                            Divider().overlay(JcTheme.border)
                            field("PIN", text: $pin, placeholder: "1234", keyboard: .numberPad)
                        }
                    }
                    Text("Open Moonlight on the device and choose this host. It shows a PIN — enter it here within a few seconds.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                    if let error {
                        IntegrationUIErrorLine(text: error).padding(.top, 12)
                    }
                    GradientButton("Pair", busy: busy, full: true, action: canPair ? pair : nil)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .jcPageChrome("Pair a device") {
                JcPageButton("xmark", label: "Close") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 16))
                .foregroundStyle(JcTheme.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }

    private func pair() {
        busy = true
        error = nil
        Task {
            let outcome = await store.pair(device: device.trimmingCharacters(in: .whitespaces),
                                           pin: pin.trimmingCharacters(in: .whitespaces))
            busy = false
            switch outcome {
            case .paired(let detail):
                onResult(detail ?? "Paired \(device)")
                dismiss()
            case .offline(let message):
                error = message
            case .failed(let message):
                error = message
            }
        }
    }
}

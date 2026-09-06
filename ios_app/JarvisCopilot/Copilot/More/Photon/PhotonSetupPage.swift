import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Photon (hosted iMessage) setup, ported from `pages/photon_setup_page.dart`.
///
/// The two secrets are write-only: the GET never returns their values, only
/// `*_set` flags. When one is stored the field shows a dotted placeholder and a
/// "leave blank to keep" hint, and `PhotonStore.save()` omits a secret the user
/// didn't retype — sending "" would wipe it server-side.
struct PhotonSetupPage: View {
    @State private var store: PhotonStore

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: PhotonStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { PhotonStore() })
    }

    var body: some View {
        @Bindable var store = store
        return Group {
            if store.isLoading {
                ProgressView().tint(JcTheme.primaryBlue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        PhotonStatusPill(status: store.status)
                            .padding(.bottom, 6)

                        PhotonInputField(label: "Project ID", text: $store.projectID,
                                    hint: "proj_…")
                        PhotonInputField(label: "Project secret", text: $store.projectSecret,
                                    hint: store.projectSecretSet ? PhotonStore.secretPlaceholder : "",
                                    secret: true, note: store.projectSecretHint)
                        PhotonInputField(label: "Notify target", text: $store.notifyTarget,
                                    hint: "phone number or email",
                                    keyboard: .emailAddress,
                                    note: "Where Jarvis sends you iMessages.")
                        PhotonInputField(label: "Sidecar URL", text: $store.sidecarURL,
                                    hint: "http://127.0.0.1:8787",
                                    keyboard: .URL,
                                    note: "The local Photon sidecar address on your Mac.")
                        PhotonInputField(label: "Sidecar token", text: $store.sidecarToken,
                                    hint: store.sidecarTokenSet ? PhotonStore.secretPlaceholder : "",
                                    secret: true, note: store.sidecarTokenHint)
                        PhotonInputField(label: "Allowed users", text: $store.allowedUsers,
                                    hint: "comma-separated handles",
                                    note: "Who may message Jarvis. Leave blank to allow any.")

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $store.allowAll) {
                                Text("Allow all inbound senders")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(JcTheme.text)
                            }
                            .tint(JcTheme.primaryBlue)
                            Text("Recommended when it's just you texting Jarvis. "
                               + "Restart the gateway to apply.")
                                .font(.system(size: 11))
                                .foregroundStyle(JcTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let message = store.errorMessage {
                            Text(message).font(JcText.body).foregroundStyle(JcTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        BlueButton("Save", busy: store.isSaving) {
                            Task { await store.save() }
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .jcScreen("Photon (iMessage)")
        .task { if store.isLoading { store.load() } }
        .moreToast($store.toast)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect hosted iMessage")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(JcTheme.text)
            Text("Create a project at app.photon.codes, then paste its credentials "
               + "from the project settings page. The Photon sidecar must be running "
               + "on your Mac for messages to send.")
                .font(JcText.body)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One labelled input: bold caption, frosted field, optional muted note under it.
/// Named `PhotonInputField` because `PhotonField` is the MODEL of one server-
/// described field (`PhotonModels.swift`).
struct PhotonInputField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""
    var secret: Bool = false
    var keyboard: UIKeyboardType = .default
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Group {
                if secret {
                    SecureField(hint, text: $text)
                } else {
                    TextField(hint, text: $text)
                }
            }
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .jcFieldStyle()
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The connection/health banner: a tinted icon + label from `PhotonStatus`.
struct PhotonStatusPill: View {
    let status: PhotonStatus

    var body: some View {
        let tint = Color(tone: status.tone)
        HStack(spacing: 10) {
            Image(systemName: status.iconName).font(.system(size: 18)).foregroundStyle(tint)
            Text(status.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

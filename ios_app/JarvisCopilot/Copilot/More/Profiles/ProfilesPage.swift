import SwiftUI

/// The "Profiles" screen, ported from `pages/more/profiles_page.dart`.
///
/// Lists every profile, switches the active one, creates new ones (optionally
/// cloned) and deletes non-default, non-active ones. There is no Edit action by
/// design — the server has no profile-edit endpoint. On top sits a preview of the
/// active personality prompt, which is what actually gives the active profile its
/// voice.
struct ProfilesPage: View {
    @State private var store: ProfilesStore
    @State private var creating = false
    @State private var detail: Profile?
    @State private var personality = ""

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: ProfilesStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { ProfilesStore() })
    }

    var body: some View {
        content
            .loadErrorBanner(store.errorMessage, hasContent: !store.profiles.isEmpty)
            .jcScreen("Profiles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New profile")
                }
            }
            .task {
                if !store.hasLoaded { store.load() }
                personality = await store.activePersonality()
            }
            .moreToast($store.toast)
            .sheet(isPresented: $creating) { ProfileCreateSheet(store: store) }
            .sheet(item: $detail) { profile in
                ProfileDetailSheet(store: store, profile: profile)
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage, store.profiles.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !personality.isEmpty {
                        ProfilePersonalityCard(prompt: personality)
                            .padding(.bottom, 8)
                    }
                    if store.isEmpty {
                        CenteredMessage(text: "No profiles yet.").padding(.top, 60)
                    } else {
                        ForEach(store.profiles) { profile in
                            Button { detail = profile } label: {
                                ProfileCard(profile: profile, isActive: store.isActive(profile))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable {
                await store.refresh()
                personality = await store.activePersonality()
            }
        }
    }
}

/// The active JARVIS system prompt, collapsed to a few lines with a tap to
/// expand. Read-only — this screen can't author personalities.
struct ProfilePersonalityCard: View {
    let prompt: String
    @State private var expanded = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ACTIVE PERSONALITY")
                        .font(.system(size: 10.5, weight: .bold)).kerning(0.6)
                        .foregroundStyle(JcTheme.muted)
                    Spacer(minLength: 8)
                    Button(expanded ? "Less" : "More") { expanded.toggle() }
                        .font(JcText.small.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
                Text(prompt)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }
}

/// One profile row: a gateway-state rail, the name with ACTIVE / DEFAULT pills,
/// and "model · provider".
struct ProfileCard: View {
    let profile: Profile
    let isActive: Bool

    private var dotColor: Color { Color(tone: profile.gatewayTone) }

    private var subtitle: String {
        [profile.model, profile.provider].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        GlassCard(padding: 14, blur: false,
                  borderColor: isActive ? JcTheme.success.opacity(0.40) : JcTheme.glassBorder) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if profile.gatewayRunning {
                        PulsingDot(color: dotColor, size: 9)
                    } else {
                        Circle().fill(dotColor).frame(width: 9, height: 9)
                    }
                }
                .padding(.top, 5)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(profile.name.isEmpty ? "(unnamed)" : profile.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if isActive { StatusPill("ACTIVE", color: JcTheme.success, dense: true) }
                        if profile.isDefault { StatusPill("DEFAULT", color: JcTheme.blue, dense: true) }
                    }
                    if !subtitle.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                            Text(subtitle)
                                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.muted.opacity(0.7))
                    .padding(.top, 3)
            }
        }
    }
}

/// The tap-through sheet: status pills, the record's fields, then Switch and
/// (when allowed) Delete.
struct ProfileDetailSheet: View {
    let store: ProfilesStore
    let profile: Profile

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var isActive: Bool { store.isActive(profile) }

    var body: some View {
        DetailSheet(title: profile.name.isEmpty ? "Profile" : profile.name) {
            VStack(alignment: .leading, spacing: 14) {
                JcWrap(spacing: 8, runSpacing: 8) {
                    if isActive { StatusPill("ACTIVE", color: JcTheme.success) }
                    if profile.isDefault { StatusPill("DEFAULT", color: JcTheme.blue) }
                    StatusPill(profile.gatewayLabel, color: Color(tone: profile.gatewayTone),
                               live: profile.gatewayRunning)
                }
                VStack(alignment: .leading, spacing: 0) {
                    DetailSheetRow("Name", profile.name)
                    DetailSheetRow("Model", profile.model)
                    DetailSheetRow("Provider", profile.provider)
                    DetailSheetRow("Path", profile.path)
                }
            }
        } actions: {
            if !isActive {
                GradientButton("Switch to this profile", symbol: "arrow.left.arrow.right") {
                    dismiss()
                    Task { await store.switchTo(profile.name) }
                }
            }
            if store.canDelete(profile) {
                GlassButton(title: "Delete", symbol: "trash", ghost: true) {
                    confirmDelete = true
                }
            }
        }
        .alert("Delete profile?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                dismiss()
                Task { await store.delete(profile.name) }
            }
        } message: {
            Text("This permanently deletes the \"\(profile.name)\" profile and its data. "
               + "This cannot be undone.")
        }
    }
}

/// "New profile": name (required), an optional clone source, and the optional
/// connection overrides. Blank fields are omitted so the server keeps defaults.
struct ProfileCreateSheet: View {
    let store: ProfilesStore

    @State private var name = ""
    @State private var cloneFrom = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var provider = ""

    /// "" is the "None" sentinel — `PickerField` needs a non-optional Hashable,
    /// and the store already treats an empty clone source as "don't clone".
    private var cloneOptions: [PickerOption<String>] {
        [PickerOption("", "None", symbol: "slash.circle")]
            + store.cloneCandidates.map { PickerOption($0, $0, symbol: "person.crop.circle") }
    }

    var body: some View {
        FormSheet(title: "New profile", saveLabel: "Create", onSave: save) {
            FormTextField(label: "Name (required)", text: $name,
                          hint: "lowercase, digits, - or _")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FormDropdown(label: "Clone from (optional)", selection: $cloneFrom,
                         options: cloneOptions)
            FormTextField(label: "Base URL", text: $baseURL, hint: "https://...")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FormTextField(label: "API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FormTextField(label: "Default model", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FormTextField(label: "Model provider", text: $provider)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func save() async -> Bool {
        await store.create(name: name,
                           cloneFrom: cloneFrom.isEmpty ? nil : cloneFrom,
                           baseURL: baseURL, apiKey: apiKey,
                           defaultModel: model, modelProvider: provider)
    }
}

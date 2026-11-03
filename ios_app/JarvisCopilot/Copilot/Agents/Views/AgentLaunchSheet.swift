import SwiftUI

/// "+" in the Agents tab: start a Claude Code or Codex session in a folder, on
/// the server or on a connected Mac (`POST /agents/launch`). It shows up in
/// the list from its own hooks a moment later. There is no tmux any more, so
/// no worktree or title.
///
/// Laid out like a system sheet: Cancel and the title in the bar, grouped glass
/// cards for where / which agent / folder / options / first message, and one
/// accent Start pinned above the keyboard.
struct AgentLaunchSheet: View {
    let store: AgentsStore

    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    /// "server" or a Mac's device id.
    @State private var place = "server"
    @State private var agent = "claude"
    @State private var model = ""
    @State private var permissionMode = ""
    @State private var prompt = ""
    @State private var macs: [CodingDevice] = []
    @State private var error: String?
    @State private var launching = false
    /// Remembered: once on, every new Claude session starts with Remote Control.
    @AppStorage("agents.launch.remoteControl") private var remoteControl = false
    @FocusState private var promptFocused: Bool

    static let permissionModes: [PickerOption<String>] = [
        PickerOption("", "Ask before acting", subtitle: "The default", symbol: "hand.raised"),
        PickerOption("acceptEdits", "Accept file edits", symbol: "pencil"),
        PickerOption("plan", "Plan first", symbol: "list.bullet"),
        PickerOption("bypassPermissions", "Skip all permission prompts", symbol: "exclamationmark.shield"),
    ]

    private struct Place: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let detail: String
    }

    private var places: [Place] {
        [Place(id: "server", name: "Server", symbol: "server.rack", detail: "Always on")]
            + macs.filter(\.online).map { Place(id: $0.id, name: $0.name, symbol: "laptopcomputer", detail: "Online") }
    }

    private var placeName: String { places.first { $0.id == place }?.name ?? "Server" }
    private var isClaude: Bool { agent == "claude" }
    private var permission: PickerOption<String> {
        Self.permissionModes.first { $0.value == permissionMode } ?? Self.permissionModes[0]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section("Run on") { placeGrid }
                    section("Agent") { agentGrid }
                    section("Folder", footer: "On \(placeName). A folder that doesn't exist yet is created") {
                        AgentDirSuggestField(
                            path: $cwd,
                            hint: place == "server" ? "~/codingprojects/your-project" : "~/code/your-project",
                            scope: place,
                            fetch: { await store.api.dirSuggest(path: $0, deviceId: place == "server" ? nil : place) })
                    }
                    if isClaude {
                        section("Options") { optionsCard }
                        section("Remote Control",
                                footer: "Stays on for new sessions until you turn it off") { remoteControlCard }
                    }
                    section("First message", footer: "Optional — without one the session waits for you") {
                        promptCard
                    }
                    if let error {
                        CodingInlineError(message: error)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
            .jcScreen("New session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(launching)
                }
            }
        }
        .animation(.snappy, value: agent)
        .animation(.snappy, value: error)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(launching)
        .task { macs = (try? await store.api.desktops()) ?? [] }
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, footer: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title).padding(.horizontal, 4)
            content()
            if let footer {
                Text(footer)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
            }
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var placeGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(places) { p in
                LaunchTile(title: p.name, detail: p.detail, selected: place == p.id) {
                    place = p.id
                } icon: { selected in
                    JcIcon(p.symbol, size: 18)
                        .foregroundStyle(selected ? JcTheme.accent : JcTheme.text)
                }
            }
        }
    }

    private var agentGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach([("claude", "Claude Code", "Anthropic"), ("codex", "Codex", "OpenAI")], id: \.0) { a in
                LaunchTile(title: a.1, detail: a.2, selected: agent == a.0) {
                    agent = a.0
                } icon: { selected in
                    AgentLogoMark(agent: a.0, size: 20, ring: false,
                                  tint: selected ? JcTheme.accent : JcTheme.text)
                }
            }
        }
    }

    private var optionsCard: some View {
        GlassGroup {
            LaunchOptionRow(symbol: "cpu", title: "Model", subtitle: "Blank uses the default") {
                TextField("Default", text: $model)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 150)
            }
            Menu {
                Picker("Permissions", selection: $permissionMode) {
                    ForEach(Self.permissionModes) { option in
                        Label(option.label, systemImage: option.symbol ?? "circle").tag(option.value)
                    }
                }
            } label: {
                LaunchOptionRow(symbol: permission.symbol ?? "hand.raised", title: "Permissions",
                                subtitle: permission.label,
                                // Skipping every prompt is the risky one: amber, like a warning.
                                iconTint: permissionMode == "bypassPermissions" ? JcTheme.amber : nil,
                                last: true) {
                    JcIcon("chevron.up.chevron.down", size: 13, weight: .semibold)
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var remoteControlCard: some View {
        GlassGroup {
            LaunchOptionRow(symbol: "antenna.radiowaves.left.and.right", title: "Remote Control",
                            subtitle: "Control this session from claude.ai/code and the Claude app",
                            subtitleLines: 2, last: true) {
                Toggle("Remote Control", isOn: $remoteControl)
                    .labelsHidden()
                    .tint(JcTheme.accent)
            }
        }
    }

    private var promptCard: some View {
        TextField("What should it work on?", text: $prompt, axis: .vertical)
            .lineLimit(4...10)
            .font(JcText.body)
            .foregroundStyle(JcTheme.text)
            .focused($promptFocused)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .fill(JcTheme.glassFill))
            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .strokeBorder(promptFocused ? JcTheme.accent.opacity(0.55) : JcTheme.glassBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { promptFocused = true }
    }

    // MARK: start

    private var summary: String {
        var parts = [isClaude ? "Claude Code" : "Codex", placeName]
        if isClaude && remoteControl { parts.append("Remote Control") }
        return parts.joined(separator: " · ")
    }

    private var startBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await launch() }
            } label: {
                HStack(spacing: 8) {
                    if launching {
                        ProgressView().controlSize(.small).tint(JcTheme.accent)
                    } else {
                        JcIcon("play.fill", size: 15)
                    }
                    Text(launching ? "Starting…" : "Start session")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .jcLiquidGlass(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(launching)
            .opacity(launching ? 0.7 : 1)
            .accessibilityHint(summary)
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 6)
        // Opaque behind the button itself: the glass would otherwise refract the
        // cards scrolling under it into ghost text.
        .background(
            LinearGradient(stops: [.init(color: JcTheme.bg.opacity(0), location: 0),
                                   .init(color: JcTheme.bg, location: 0.18),
                                   .init(color: JcTheme.bg, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private func launch() async {
        let dir = jcTrim(cwd)
        guard !dir.isEmpty else {
            error = "Pick a folder."
            return
        }
        error = nil
        launching = true
        defer { launching = false }
        let failure = await store.launch(cwd: dir, where: place, agent: agent,
                                         model: isClaude ? jcTrim(model) : nil,
                                         permissionMode: isClaude ? permissionMode : nil,
                                         prompt: jcTrim(prompt),
                                         remoteControl: isClaude && remoteControl)
        if let failure { error = failure } else { dismiss() }
    }
}

/// One choice in a two-column grid (where to run, which agent): an icon on a
/// glass disc, a name and a muted line; the chosen one washed and rimmed in the
/// accent with a check.
private struct LaunchTile<Icon: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    let icon: (Bool) -> Icon

    init(title: String, detail: String, selected: Bool, action: @escaping () -> Void,
         @ViewBuilder icon: @escaping (Bool) -> Icon) {
        self.title = title
        self.detail = detail
        self.selected = selected
        self.action = action
        self.icon = icon
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    icon(selected)
                        .frame(width: 38, height: 38)
                        .background((selected ? JcTheme.accent : Color.white).opacity(selected ? 0.14 : 0.06),
                                    in: Circle())
                        .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    Spacer(minLength: 4)
                    JcIcon(selected ? "checkmark.circle.fill" : "circle", size: 18)
                        .foregroundStyle(selected ? JcTheme.accent : JcTheme.muted.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .jcLiquidGlass(in: shape, tint: selected ? JcTheme.accent.opacity(0.16) : .clear)
            .overlay(shape.strokeBorder(selected ? JcTheme.accent.opacity(0.7) : JcTheme.glassBorder,
                                        lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected) { _, now in now }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A settings-style row inside a `GlassGroup`: icon disc, title over a muted
/// line, and a control on the trailing edge. Like `GlassRow`, with the icon's
/// colour settable on its own (a warning there doesn't redden the title).
private struct LaunchOptionRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var subtitleLines: Int = 1
    var iconTint: Color? = nil
    var last: Bool = false
    @ViewBuilder var trailing: Trailing

    init(symbol: String, title: String, subtitle: String? = nil, subtitleLines: Int = 1,
         iconTint: Color? = nil, last: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.subtitleLines = subtitleLines
        self.iconTint = iconTint
        self.last = last
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                JcIcon(symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(iconTint ?? JcTheme.accent)
                    .frame(width: 34, height: 34)
                    .background((iconTint ?? Color.white).opacity(iconTint == nil ? 0.06 : 0.12), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JcText.body.weight(.semibold)).foregroundStyle(JcTheme.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(subtitleLines)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            if !last {
                Rectangle().fill(JcTheme.glassBorder)
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }
}

/// A folder field in a glass card that offers folders on the chosen machine as
/// you type, and drills in when one is tapped. `scope` is where it looks (the
/// server or a Mac's device id): changing it drops the stale list and asks again.
struct AgentDirSuggestField: View {
    @Binding var path: String
    var hint: String = ""
    let scope: String
    let fetch: (String) async -> [String]

    @State private var suggestions: [String] = []
    @State private var queryToken = 0
    @FocusState private var focused: Bool

    var body: some View {
        GlassGroup {
            HStack(spacing: 12) {
                JcIcon("folder")
                    .font(.system(size: 17))
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                TextField(hint, text: $path)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                if !path.isEmpty {
                    Button { path = "" } label: {
                        JcIcon("xmark.circle.fill", size: 16).foregroundStyle(JcTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear folder")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if focused && !suggestions.isEmpty {
                ForEach(suggestions.prefix(6), id: \.self) { dir in
                    Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 60)
                    Button { pick(dir) } label: {
                        HStack(spacing: 12) {
                            JcIcon("folder", size: 14)
                                .foregroundStyle(JcTheme.muted)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(CodingJSON.basename(dir))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(JcTheme.text)
                                    .lineLimit(1)
                                Text(dir)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(JcTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                            JcIcon("chevron.right", size: 12, weight: .semibold)
                                .foregroundStyle(JcTheme.muted.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(focused ? JcTheme.accent.opacity(0.55) : .clear, lineWidth: 1))
        .animation(.snappy(duration: 0.2), value: suggestions)
        .onChange(of: path) { _, _ in queryToken += 1 }
        .onChange(of: focused) { _, isFocused in
            if isFocused { queryToken += 1 } else { suggestions = [] }
        }
        .onChange(of: scope) { _, _ in
            suggestions = []
            queryToken += 1
        }
        // `.task(id:)` cancels the previous lookup: both the debounce and the
        // stale-response guard. Only a focused field asks.
        .task(id: queryToken) {
            guard focused else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            if Task.isCancelled { return }
            let dirs = await fetch(path)
            if !Task.isCancelled { suggestions = dirs }
        }
    }

    private func pick(_ dir: String) {
        // The trailing separator makes the next query list the folder's children.
        path = dir.hasSuffix("/") ? dir : dir + "/"
        // Tapping the row can resign the field; keep drilling in.
        focused = true
    }
}

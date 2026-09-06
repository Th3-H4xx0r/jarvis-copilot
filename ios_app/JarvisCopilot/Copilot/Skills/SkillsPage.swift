import SwiftUI

/// The Skills tab, ported from `pages/skills_page.dart` and grown to cover what
/// the Flutter screen couldn't.
///
/// Per-skill switches are a real ACL: a skill switched off is left out of the
/// bridge's register manifest AND refused by `InvokeRunner`, so the server never
/// sees it. On top of that the screen adds the two things you want when a remote
/// invoke misbehaves — a master pause for the invoke runner, and the in-session
/// invoke log — plus "Test skill", which runs one locally through the same
/// runner so what you see is exactly what the server would get back.
struct SkillsPage: View {
    @State private var model: SkillsPageModel
    @State private var testing: SkillListItem?

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the model can't be a default argument.
    init(model: SkillsPageModel? = nil) {
        _model = State(initialValue: model ?? MainActor.assumeIsolated { SkillsPageModel() })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SkillsRunnerCard(paused: model.paused) { model.setPaused($0) }
                    catalogue
                    SkillsInvokeLog(rows: model.log) { model.reloadLog() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            // Under the navigation bar, not iOS 26's default floating bar: that
            // one docks to the bottom of the screen, where it stacks on top of
            // the shell's own floating nav pill and covers a skill row.
            .searchable(text: searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search skills")
            .jcScreen("Skills")
        }
        .onAppear { model.reload() }
        .sheet(item: $testing) { item in
            SkillTestSheet(model: model, skill: item)
        }
    }

    /// `model.query` is a plain `var` on an `@Observable` class, so it needs an
    /// explicit binding rather than `$model.query` on a `@State` box.
    private var searchText: Binding<String> {
        Binding(get: { model.query }, set: { model.query = $0 })
    }

    @ViewBuilder
    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("This phone's skills") {
                Text(model.summary).font(JcText.small).foregroundStyle(JcTheme.muted)
            }
            if model.isEmpty {
                CenteredMessage(text: "No native skills are registered on this device.")
            } else if !model.hasResults {
                CenteredMessage(text: "No skill matches “\(model.query)”.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .bold)).kerning(0.8)
                                .foregroundStyle(JcTheme.muted)
                                .padding(.leading, 4)
                            GlassGroup(blur: false) {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                    SkillToggleRow(item: item,
                                                   last: index == section.items.count - 1,
                                                   onToggle: { model.setEnabled($0, for: item.name) },
                                                   onTest: { testing = item })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One skill: glyph, monospaced name, description, a Test button and the switch.
struct SkillToggleRow: View {
    let item: SkillListItem
    let last: Bool
    let onToggle: (Bool) -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GlassCircleIcon(symbol: item.requiresForeground ? "shield" : "chevron.left.forwardslash.chevron.right",
                                tint: item.requiresForeground ? JcTheme.accent : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onTest) {
                    Text("Test")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(JcTheme.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(JcTheme.cyan.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(JcTheme.cyan.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Test \(item.name)")
                Toggle("", isOn: Binding(get: { item.enabled }, set: onToggle))
                    .labelsHidden()
                    .tint(JcTheme.primaryBlue)
                    .accessibilityLabel(item.name)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !last {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 68)
            }
        }
    }
}

/// The master switch for remote invokes. Paused is a hard stop — every invoke
/// answers `paused` without touching the skill — so it says so plainly.
struct SkillsRunnerCard: View {
    let paused: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { paused }, set: onChange)) {
                    HStack(spacing: 8) {
                        Image(systemName: paused ? "pause.circle.fill" : "play.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(paused ? JcTheme.amber : JcTheme.success)
                        Text("Invoke runner paused")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                    }
                }
                .tint(JcTheme.amber)
                Text(paused
                     ? "Every incoming invoke is refused with \"paused\" until you switch this back."
                     : "Skills run as the server asks for them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The in-session invoke trace, newest first. Bounded by the runner (200 rows),
/// and read on demand — nothing here observes, so the header carries a reload.
struct SkillsInvokeLog: View {
    let rows: [SkillInvokeLogRow]
    let onReload: () -> Void

    /// Enough to see what just happened without turning the tab into a log file.
    private static let visible = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Recent invokes") {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload invoke log")
            }
            if rows.isEmpty {
                GlassCard(padding: 14, blur: false) {
                    Text("Nothing has been invoked in this session yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(rows.prefix(Self.visible)) { row in
                        SkillsInvokeLogCard(row: row)
                    }
                }
            }
        }
    }
}

struct SkillsInvokeLogCard: View {
    let row: SkillInvokeLogRow

    var body: some View {
        GlassCard(padding: 12, blur: false) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.skill)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    StatusPill(row.failed ? "FAILED" : "OK",
                               color: row.failed ? JcTheme.danger : JcTheme.success, dense: true)
                    Spacer(minLength: 4)
                    Text(row.timeLabel).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                }
                if !row.argsSummary.isEmpty {
                    Text(row.argsSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(3)
                }
                Text(row.outcome)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(row.failed ? JcTheme.danger : JcTheme.text)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Test skill": a form built from the skill's own JSON Schema, then the raw
/// result (or error) the runner produced.
struct SkillTestSheet: View {
    let model: SkillsPageModel
    let skill: SkillListItem

    @State private var values: [String: String] = [:]
    @State private var result: String?
    @State private var running = false

    private var fields: [SkillArgField] { model.fields(for: skill.name) }

    var body: some View {
        DetailSheet(title: "Test \(skill.name)") {
            VStack(alignment: .leading, spacing: 14) {
                if !skill.detail.isEmpty {
                    Text(skill.detail)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if fields.isEmpty {
                    Text("This skill takes no arguments.")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                } else {
                    ForEach(fields) { field in
                        SkillArgFieldView(field: field, text: binding(for: field.key))
                    }
                }
                if let result {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RESULT")
                            .font(.system(size: 10.5, weight: .bold)).kerning(0.6)
                            .foregroundStyle(JcTheme.muted)
                        Text(result)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(result.hasPrefix("error:") ? JcTheme.danger : JcTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(JcTheme.glassFill,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }
        } actions: {
            GradientButton("Run", symbol: "play.fill", busy: running) {
                Task { await run() }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func run() async {
        running = true
        result = await model.run(skill.name,
                                 arguments: SkillArgsForm.arguments(values, fields: fields))
        running = false
    }
}

/// One argument input. A `choice` becomes a menu, everything else a text field
/// with the keyboard its type implies.
struct SkillArgFieldView: View {
    let field: SkillArgField
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field.key)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JcTheme.text)
                if field.required {
                    Text("REQUIRED")
                        .font(.system(size: 9, weight: .bold)).kerning(0.4)
                        .foregroundStyle(JcTheme.amber)
                }
                Spacer(minLength: 0)
            }
            switch field.kind {
            case .choice:
                Menu {
                    ForEach(field.options, id: \.self) { option in
                        Button(option) { text = option }
                    }
                } label: {
                    HStack {
                        Text(text.isEmpty ? "Choose…" : text)
                            .font(JcText.body)
                            .foregroundStyle(text.isEmpty ? JcTheme.muted : JcTheme.text)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(JcTheme.glassFill,
                                in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            case .boolean:
                Toggle(isOn: Binding(get: { text.lowercased() == "true" },
                                     set: { text = $0 ? "true" : "false" })) {
                    Text(text.lowercased() == "true" ? "true" : "false")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(JcTheme.muted)
                }
                .tint(JcTheme.primaryBlue)
            default:
                TextField(field.detail.isEmpty ? field.key : field.detail, text: $text)
                    .keyboardType(field.kind == .text ? .default : .numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .jcFieldStyle()
            }
            if !field.detail.isEmpty && field.kind != .text {
                Text(field.detail).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

import SwiftUI

/// More → Harnesses: the built-ins and your own harnesses, the one Default with
/// Voice/Chat's own picks, and the way into the canvas editor. Built-ins open
/// read-only and are duplicated to edit.
struct HarnessesPage: View {
    @State private var editing: AgentHarness?
    private var store: HarnessStore { HarnessStore.shared }

    var body: some View {
        ScrollView {
            JcPageColumn {
                JcSectionLabel("Defaults", first: true)
                JcCard(padding: 0) {
                    JcRow(title: "Default", fixedTitle: true) {
                        Self.valueMenu("Default", value: store.title(for: store.assignments["default"] ?? store.defaultID),
                                  selection: Binding(
                                    get: { store.defaultID },
                                    set: { id in Task { await store.assign(id, to: "default") } })) {
                            ForEach(store.harnesses) { Text($0.title).tag($0.id) }
                        }
                    }
                    overrideRow("Voice", .voice)
                    overrideRow("Chat", .chat, last: true)
                }
                footer("New chats, your devices, Telegram/iMessage and schedules use the Default; "
                       + "Voice and Chat can use their own. A chat can still switch from its header.")

                JcSectionLabel("Harnesses")
                JcCard(padding: 0) {
                    ForEach(store.harnesses) { harness in
                        row(harness, last: harness.id == store.harnesses.last?.id)
                            .contextMenu {
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    editing = copy(of: harness)
                                }
                                if !harness.isBuiltin {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await store.delete(harness.id) }
                                    }
                                }
                            }
                    }
                }

                if let message = store.errorMessage {
                    footer(message)
                }
            }
        }
        .jcPageChrome("Harnesses")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                JcPageButton("plus", label: "New harness") {
                    editing = HarnessGraph.newHarness(id: uniqueID("harness"), name: "New harness")
                }
            }
        }
        .navigationDestination(item: $editing) { HarnessEditorView(harness: $0) }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    /// A muted line under a card (the footer the old grouped list had).
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(JcText.small)
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    private func row(_ harness: AgentHarness, last: Bool) -> some View {
        let uses = [store.defaultID == harness.id ? "Default" : nil,
                    store.overrides["voice"] == harness.id ? "Voice" : nil,
                    store.overrides["chat"] == harness.id ? "Chat" : nil].compactMap { $0 }
        let subtitle = ((harness.isBuiltin ? ["Built-in"] : []) + uses).joined(separator: " · ")
        return JcRow(title: harness.title, subtitle: subtitle.isEmpty ? nil : subtitle,
                     last: last, action: { editing = harness }) {
            HStack(spacing: 10) {
                if !(harness.problems ?? []).isEmpty {
                    JcIcon("exclamationmark.triangle").foregroundStyle(JcTheme.amber)
                }
                // Capped, so a long harness's glyph can't take the row from its name.
                HarnessMiniDiagram(harness: harness, maxSteps: 3)
                JcRowChevron()
            }
        }
    }

    /// Voice / Chat: "Same as default (Name)" in the menu (tag "", clears the
    /// override), then each harness. The row itself just says "Same as default" —
    /// the Default row right above names it.
    private func overrideRow(_ title: String, _ surface: VoiceSurface, last: Bool = false) -> some View {
        let own = store.overrides[surface.rawValue] ?? ""
        return JcRow(title: title, last: last, fixedTitle: true) {
            Self.valueMenu(title, value: own.isEmpty ? Self.followsDefault : store.title(for: own),
                      selection: Binding(
                        get: { store.overrides[surface.rawValue] ?? "" },
                        set: { id in Task { await store.assign(id, to: surface) } })) {
                Text(store.sameAsDefaultTitle).tag("")
                ForEach(store.harnesses) { Text($0.title).tag($0.id) }
            }
        }
    }

    /// What a Voice/Chat row says while it follows the default. Short: the long
    /// "Same as default (Name)" wrapped to three lines there.
    static let followsDefault = "Same as default"

    /// A row's value as a menu: the pick in muted text on ONE line, cut at the
    /// tail, with the up/down chevron the app's other menu values use. A system
    /// `.menu` Picker wrapped a long harness name over three lines while reporting
    /// one line's height, so the card clipped the Chat row — and, laid out first,
    /// it crushed the row's label to a letter a line.
    static func valueMenu<Options: View>(_ title: String, value: String, selection: Binding<String>,
                                         @ViewBuilder options: () -> Options) -> some View {
        let items = options()
        return Menu {
            Picker(title, selection: selection) { items }
        } label: {
            HStack(spacing: 4) {
                JcRowValue(text: value)
                    .truncationMode(.tail)
                JcIcon("chevron.up.chevron.down", size: 11)
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .accessibilityLabel("\(title): \(value)")
        // Ahead of the row's spacer, so the value uses the room the label leaves.
        .layoutPriority(1)
    }

    private func copy(of harness: AgentHarness) -> AgentHarness {
        HarnessGraph.duplicate(harness, id: uniqueID("\(harness.id)-copy"), name: "\(harness.name) copy")
    }

    private func uniqueID(_ base: String) -> String {
        var id = base
        var n = 2
        while store.harness(id) != nil { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

import SwiftUI

/// Read-only mirror of the webui "Todos" panel, ported from `todos_page.dart`:
/// the active chat session's todo list, derived from its message history (there
/// is no todos API). Active work sorts to the top — `TodosStore` owns that.
struct TodosPage: View {
    @State private var store: TodosStore

    /// A view's `init` is not main-actor-isolated, so the `@MainActor` store
    /// can't be a default argument (see `SettingsPage.init`).
    init(store: TodosStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { TodosStore() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        // A failed pull-to-refresh with rows already on screen is otherwise
        // silent — the list just stays stale.
        .loadErrorBanner(store.errorMessage, hasContent: !store.todos.isEmpty)
        .jcScreen("Todos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "arrow.clockwise", size: 34, iconSize: 16) {
                    store.load()
                }
            }
        }
        // Loading is kicked once; pull-to-refresh handles every re-read after.
        .task { if !store.hasLoaded { store.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage, store.todos.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 100)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if store.todos.isEmpty {
            TodosEmptyState().padding(.top, 100)
        } else {
            SectionHeader("Active session") {
                Text(store.progressLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
            }
            // Todo ids come from the agent and are not guaranteed unique (or even
            // present), so the row index is the identity here.
            ForEach(Array(store.todos.enumerated()), id: \.offset) { _, todo in
                TodoCard(todo: todo)
            }
        }
    }
}

/// One todo: status glyph, the text (struck through once finished) and a pill.
struct TodoCard: View {
    let todo: TodoItem

    private var style: TodoStatusStyle { todo.style }
    private var active: Bool { todo.status == "in_progress" }
    private var tone: Color { Color(tone: style.tone) }

    var body: some View {
        GlassCard(padding: 14, blur: false,
                  borderColor: active ? JcTheme.primaryBlue.opacity(0.40) : nil) {
            HStack(alignment: .top, spacing: 12) {
                icon.padding(.top, 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(todo.content.isEmpty ? "(empty)" : todo.content)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(style.strikethrough ? JcTheme.muted : JcTheme.text)
                        .strikethrough(style.strikethrough, color: JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    StatusPill(style.label, color: tone, live: active, dense: true)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if style.spin {
            TodoSpinningIcon(symbol: style.iconName, color: tone)
        } else {
            Image(systemName: style.iconName).font(.system(size: 18)).foregroundStyle(tone)
        }
    }
}

/// The in-progress glyph, turning slowly so live work reads as live.
struct TodoSpinningIcon: View {
    let symbol: String
    let color: Color

    @State private var spinning = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Icon + text empty state for a session with no plan.
struct TodosEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checklist")
                .font(.system(size: 28))
                .foregroundStyle(JcTheme.muted.opacity(0.8))
                .frame(width: 64, height: 64)
                .background(JcTheme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                .padding(.bottom, 16)
            Text("No active todo list.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .padding(.bottom, 6)
            Text("When the active chat session has a plan, its todos show here.")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

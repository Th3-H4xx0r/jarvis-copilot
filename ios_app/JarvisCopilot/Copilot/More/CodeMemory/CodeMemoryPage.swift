import SwiftUI

/// The shared per-project code-memory store — the knowledge and session handoffs
/// Claude / the JarvisCopilot agent write while working in a repo. Ported from
/// `code_memory_page.dart`.
///
/// Overview: totals header, a client-side project filter, and a project list.
/// Tapping a project pushes `CodeMemoryProjectPage` (Knowledge / Handoffs).
struct CodeMemoryPage: View {
    @State private var store: CodeMemoryStore

    init(store: CodeMemoryStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { CodeMemoryStore() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .scrollDismissesKeyboard(.interactively)
        .loadErrorBanner(store.errorMessage, hasContent: !store.overview.projects.isEmpty)
        .jcScreen("Code memory")
        .task { if !store.hasLoaded { store.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage, store.overview.projects.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 100)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if store.isEmpty {
            CenteredMessage(text: "No code memory yet.\n\nKnowledge and session handoffs "
                                + "appear here as Claude or the JarvisCopilot agent stores "
                                + "them for a repo.")
                .padding(.top, 100)
        } else {
            CodeMemoryStatsHeader(overview: store.overview).padding(.bottom, 14)
            CodeMemorySearchField(text: $store.filter, hint: "Search projects…")
                .padding(.bottom, 12)
            if store.filterMatchedNothing {
                CodeMemoryEmptyState(symbol: "magnifyingglass", message: "No matching projects.")
                    .padding(.top, 48)
            } else {
                ForEach(store.visibleProjects) { project in
                    NavigationLink {
                        CodeMemoryProjectPage(project: project,
                                              knowledge: store.entriesStore(slug: project.slug,
                                                                            kind: .knowledge),
                                              handoffs: store.entriesStore(slug: project.slug,
                                                                           kind: .sessions),
                                              onChanged: { Task { await store.refresh() } })
                    } label: {
                        CodeMemoryProjectRow(project: project)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

/// Projects / Knowledge / Handoffs totals plus the last-active line.
struct CodeMemoryStatsHeader: View {
    let overview: CodeMemoryOverview

    var body: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    stat("folder", JcTheme.blue, "Projects", overview.totalProjects)
                    divider
                    stat("lightbulb", JcTheme.cyan, "Knowledge", overview.totalKnowledge)
                    divider
                    stat("book.closed", JcTheme.accent, "Handoffs", overview.totalHandoffs)
                }
                let activity = overview.lastActivityLabel()
                if !activity.isEmpty {
                    Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                        Text("Last active \(activity)")
                            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
        }
    }

    private var divider: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(width: 1, height: 40)
    }

    private func stat(_ symbol: String, _ color: Color, _ label: String, _ value: Int) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(color)
                .padding(.bottom, 6)
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .padding(.bottom, 2)
            Text(label).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One repo: name, slug, counts and last-seen.
struct CodeMemoryProjectRow: View {
    let project: CodeMemoryProject

    var body: some View {
        GlassCard(padding: 0, blur: false) {
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 17))
                    .foregroundStyle(JcTheme.blue)
                    .frame(width: 40, height: 40)
                    .background(JcTheme.blue.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    .padding(.trailing, 12)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(project.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    if !project.slug.isEmpty && project.slug != project.title {
                        Text(project.slug)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                    JcWrap(spacing: 6, runSpacing: 6) {
                        StatusPill("\(project.knowledgeCount) knowledge",
                                   color: JcTheme.cyan, dense: true)
                        StatusPill("\(project.sessionsCount) handoffs",
                                   color: JcTheme.accent, dense: true)
                        let seen = project.lastSeenLabel()
                        if !seen.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10)).foregroundStyle(JcTheme.muted)
                                Text(seen).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.muted.opacity(0.7))
                    .padding(.top, 10)
                    .padding(.leading, 4)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 14)
        }
    }
}

/// The rounded glass search field shared by the overview and the entry lists.
struct CodeMemorySearchField: View {
    @Binding var text: String
    let hint: String
    var onSubmit: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15)).foregroundStyle(JcTheme.muted)
            TextField(hint, text: $text)
                .font(JcText.body)
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(JcTheme.glassFill,
                    in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

/// Centred glyph + message for an empty list or a filter that matched nothing.
struct CodeMemoryEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(JcTheme.muted.opacity(0.7))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

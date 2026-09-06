import SwiftUI

/// The Kanban board, ported from `kanban_page.dart`. Rendered as a status
/// grouped LIST (one section per column) rather than a horizontal board — the
/// phone-friendly shape the Flutter page settled on.
///
/// `KanbanStore` owns the SSE subscription and its 30 s polling fallback, so the
/// view only has to call `onAppear()` / `onDisappear()`.
struct KanbanPage: View {
    @State private var store: KanbanStore
    @State private var route: KanbanRoute?
    @State private var confirm: KanbanConfirm?

    init(store: KanbanStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { KanbanStore() })
    }

    var body: some View {
        VStack(spacing: 0) {
            boardSwitcher
            filterBar
            boardList
        }
        .loadErrorBanner(store.errorMessage, hasContent: !store.allTasks.isEmpty)
        .jcScreen("Kanban")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "plus", size: 34, iconSize: 16) {
                    route = .createTask
                }
            }
        }
        .onAppear { store.onAppear() }
        .onDisappear { store.onDisappear() }
        .moreToast($store.toast)
        .sheet(item: $route) { sheet(for: $0) }
        .alert(Text(confirm?.title ?? ""),
               isPresented: Binding(get: { confirm != nil },
                                    set: { if !$0 { confirm = nil } }),
               presenting: confirm) { item in
            Button("Cancel", role: .cancel) {}
            Button(item.actionLabel, role: .destructive) { perform(item) }
        } message: { item in
            Text(item.message)
        }
    }

    // MARK: Header

    private var boardSwitcher: some View {
        HStack(spacing: 10) {
            Button { if !store.boards.isEmpty { route = .boardPicker } } label: {
                GradientBorder(radius: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.split.3x1")
                            .font(.system(size: 16)).foregroundStyle(JcTheme.cyan)
                        Text(store.activeBoard?.displayName ?? store.currentSlug ?? "Board")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 12)
                }
            }
            .buttonStyle(.plain)

            KanbanHeaderButton(symbol: "bolt.fill", tint: JcTheme.primaryBlue) {
                Task { await store.runDispatcher() }
            }
            KanbanHeaderButton(symbol: "ellipsis") { route = .boardActions }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                KanbanFilterChip(label: "All", selected: store.columnFilter == nil) {
                    store.columnFilter = nil
                }
                ForEach(Kanban.columns, id: \.self) { column in
                    KanbanFilterChip(label: Kanban.columnLabel(column),
                                     selected: store.columnFilter == column) {
                        store.columnFilter = column
                    }
                }
                // The live event stream died and the board fell back to a 30 s
                // poll. Worth saying: without it "someone else moved this card"
                // silently takes half a minute to appear.
                if store.isPolling {
                    StatusPill("UPDATES DELAYED", color: JcTheme.amber, dense: true)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 50)
    }

    // MARK: Board

    @ViewBuilder
    private var boardList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let message = store.errorMessage, store.allTasks.isEmpty {
                    CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                        .padding(.top, 100)
                } else if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                } else if store.isEmpty {
                    CenteredMessage(text: "No tasks on this board yet.\nTap + to add one.")
                        .padding(.top, 100)
                } else if store.sections.isEmpty {
                    CenteredMessage(text: "No tasks in this column.").padding(.top, 100)
                } else {
                    ForEach(store.sections, id: \.column) { section in
                        KanbanSectionHeader(column: section.column, count: section.tasks.count)
                        ForEach(section.tasks) { task in
                            Button { route = .taskDetail(task) } label: {
                                KanbanTaskCard(task: task)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
    }

    // MARK: Routing

    @ViewBuilder
    private func sheet(for route: KanbanRoute) -> some View {
        switch route {
        case .createTask:
            KanbanTaskFormSheet(title: "New task", showsColumn: true) {
                title, body, column, assignee, priority in
                await store.createTask(title: title, body: body, column: column,
                                       assignee: assignee, priority: priority)
            }
        case .editTask(let task):
            KanbanTaskFormSheet(title: "Edit task", showsColumn: false, task: task) {
                title, body, _, assignee, priority in
                await store.editTask(task.id, title: title, body: body,
                                     assignee: assignee, priority: priority)
            }
        case .taskDetail(let task):
            KanbanTaskDetailView(store: store.detailStore(for: task),
                                 onRun: { await store.run(task) },
                                 onAction: { action in handle(action, on: task) })
        case .move(let task):
            PickerSheet(title: "Move to column",
                        options: Kanban.manualColumns.map {
                            PickerOption($0, Kanban.columnLabel($0), symbol: Kanban.columnIcon($0))
                        },
                        selection: Binding(get: { task.status },
                                           set: { picked in
                            guard picked != task.status else { return }
                            Task { await store.move(task.id, to: picked) }
                        }))
        case .block(let task):
            KanbanTextPromptSheet(title: "Block task", label: "Reason",
                                  hint: "Why blocked?") { reason in
                await store.block(task.id, reason: reason)
                return true
            }
        case .comment(let task):
            KanbanTextPromptSheet(title: "Add comment", label: "Comment",
                                  hint: "Your note") { text in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                await store.comment(task.id, text: text)
                return true
            }
        case .boardPicker:
            PickerSheet(title: "Switch board",
                        options: store.boards.map {
                            PickerOption($0.slug, $0.displayName,
                                         subtitle: $0.totalLabel,
                                         symbol: "rectangle.split.3x1")
                        },
                        selection: Binding(get: { store.currentSlug ?? "" },
                                           set: { picked in
                            guard !picked.isEmpty, picked != store.currentSlug else { return }
                            Task { await store.switchBoard(picked) }
                        }))
        case .boardActions:
            PickerSheet(title: "Board",
                        options: [PickerOption("create", "New board", symbol: "plus"),
                                  PickerOption("rename", "Rename board",
                                               symbol: "square.and.pencil"),
                                  PickerOption("archive", "Archive board",
                                               symbol: "archivebox")],
                        selection: Binding(get: { "" }, set: { boardAction($0) }))
        case .createBoard:
            KanbanBoardFormSheet(title: "New board", nameHint: "Board name") { name, note in
                await store.createBoard(title: name, description: note)
            }
        case .renameBoard(let board):
            KanbanBoardFormSheet(title: "Rename board", name: board.displayName,
                                 note: board.description) { name, note in
                await store.renameBoard(board.slug, name: name, description: note)
            }
        }
    }

    /// A detail-sheet action: dismiss the sheet first, then open the follow-up
    /// (SwiftUI will not swap one presented sheet for another mid-animation).
    private func handle(_ action: KanbanTaskAction, on task: KanbanTask) {
        switch action {
        case .move:    replace(with: .move(task))
        case .block:   replace(with: .block(task))
        case .unblock: route = nil; Task { await store.unblock(task.id) }
        case .comment: replace(with: .comment(task))
        case .edit:    replace(with: .editTask(task))
        case .delete:  route = nil; confirmAfterDismiss(.deleteTask(task))
        }
    }

    private func boardAction(_ action: String) {
        guard let board = store.activeBoard else {
            if action == "create" { replace(with: .createBoard) }
            return
        }
        switch action {
        case "create":  replace(with: .createBoard)
        case "rename":  replace(with: .renameBoard(board))
        case "archive": route = nil; confirmAfterDismiss(.archiveBoard(board))
        default: break
        }
    }

    private func replace(with new: KanbanRoute) {
        route = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            route = new
        }
    }

    private func confirmAfterDismiss(_ item: KanbanConfirm) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            confirm = item
        }
    }

    private func perform(_ item: KanbanConfirm) {
        switch item {
        case .deleteTask(let task): Task { await store.deleteTask(task.id) }
        case .archiveBoard(let board): Task { await store.archiveBoard(board.slug) }
        }
    }
}

// MARK: - Presentation state

/// Everything the board can present. One enum (rather than a `.sheet` per
/// case) because SwiftUI only reliably drives a single sheet per view.
enum KanbanRoute: Identifiable {
    case createTask
    case editTask(KanbanTask)
    case taskDetail(KanbanTask)
    case move(KanbanTask)
    case block(KanbanTask)
    case comment(KanbanTask)
    case boardPicker
    case boardActions
    case createBoard
    case renameBoard(KanbanBoard)

    var id: String {
        switch self {
        case .createTask: return "createTask"
        case .editTask(let t): return "editTask:\(t.id)"
        case .taskDetail(let t): return "taskDetail:\(t.id)"
        case .move(let t): return "move:\(t.id)"
        case .block(let t): return "block:\(t.id)"
        case .comment(let t): return "comment:\(t.id)"
        case .boardPicker: return "boardPicker"
        case .boardActions: return "boardActions"
        case .createBoard: return "createBoard"
        case .renameBoard(let b): return "renameBoard:\(b.slug)"
        }
    }
}

/// The destructive confirmations, behind one alert.
enum KanbanConfirm: Identifiable {
    case deleteTask(KanbanTask)
    case archiveBoard(KanbanBoard)

    var id: String {
        switch self {
        case .deleteTask(let t): return "deleteTask:\(t.id)"
        case .archiveBoard(let b): return "archiveBoard:\(b.slug)"
        }
    }

    var title: String {
        switch self {
        case .deleteTask: return "Delete task?"
        case .archiveBoard: return "Archive board?"
        }
    }

    var message: String {
        switch self {
        case .deleteTask(let t):
            return "Delete \"\(t.title.isEmpty ? t.id : t.title)\"? This cannot be undone."
        case .archiveBoard(let b):
            return "Archive \"\(b.displayName)\"? Its tasks stay on disk but the board "
                 + "is hidden from the switcher."
        }
    }

    var actionLabel: String {
        switch self {
        case .deleteTask: return "Delete"
        case .archiveBoard: return "Archive"
        }
    }
}

/// What the detail sheet asks the board to do once it has dismissed itself.
enum KanbanTaskAction {
    case move, block, unblock, comment, edit, delete
}

// MARK: - Rows

/// A column heading: a coloured dot, the name, and the task count.
struct KanbanSectionHeader: View {
    let column: String
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color(tone: Kanban.columnTone(column)))
                .frame(width: 8, height: 8)
                .padding(.trailing, 8)
            Text(Kanban.columnLabel(column).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(JcTheme.text)
                .padding(.trailing, 6)
            Text("\(count)").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

/// One task tile: title plus the "alice · P2 · due Friday" meta line.
struct KanbanTaskCard: View {
    let task: KanbanTask

    var body: some View {
        GlassCard(padding: 14, blur: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title.isEmpty ? "(untitled)" : task.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if !task.metaLine.isEmpty {
                    Text(task.metaLine)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A column filter pill; the selected one lifts with a soft white fill.
struct KanbanFilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(selected ? 0.10 : 0.045)))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: selected)
    }
}

/// The 46pt circular header action (dispatcher / board menu).
struct KanbanHeaderButton: View {
    let symbol: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(tint ?? JcTheme.text)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.045), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// One task's detail sheet: the pinned Run/Stop control, the record's fields,
/// links, comments (with an inline composer) and the lazily-loaded worker log.
///
/// `KanbanTaskDetailStore` owns the 2.5 s poll that keeps Run↔Stop and the log
/// live while the task is running or the log is open, so this view only has to
/// call `onAppear()` / `onDisappear()`.
struct KanbanTaskDetailView: View {
    @State var store: KanbanTaskDetailStore
    /// Fires the dispatcher for this task (the board owns that call).
    let onRun: () async -> Void
    /// A sheet action the board performs after dismissing this sheet.
    let onAction: (KanbanTaskAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftComment = ""

    private var task: KanbanTask { store.task }

    var body: some View {
        DetailSheet(title: task.title.isEmpty ? task.id : task.title) {
            fields
        } footer: {
            runControl
        } actions: {
            KanbanSheetAction(symbol: "arrow.left.arrow.right", label: "Move") {
                dismiss(); onAction(.move)
            }
            if task.isBlocked {
                KanbanSheetAction(symbol: "lock.open", label: "Unblock") {
                    dismiss(); onAction(.unblock)
                }
            } else {
                KanbanSheetAction(symbol: "nosign", label: "Block") {
                    dismiss(); onAction(.block)
                }
            }
            KanbanSheetAction(symbol: "bubble.left", label: "Comment") {
                dismiss(); onAction(.comment)
            }
            KanbanSheetAction(symbol: "square.and.pencil", label: "Edit") {
                dismiss(); onAction(.edit)
            }
            KanbanSheetAction(symbol: "trash", label: "Delete", danger: true) {
                dismiss(); onAction(.delete)
            }
        }
        .onAppear { store.onAppear() }
        .onDisappear { store.onDisappear() }
        .moreToast($store.toast)
    }

    // MARK: Body

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailSheetRow("Column", task.status)
            DetailSheetRow("Assignee", task.assignee)
            DetailSheetRow("Priority", task.priority)
            DetailSheetRow("Due", task.due)
            DetailSheetRow("Description", task.body)
            links
            comments
            if store.isLoadingDetail {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                composer
            }
            logSection.padding(.top, 8)
        }
    }

    @ViewBuilder
    private var links: some View {
        let parents = MoreJSON.stringList(store.links["parents"])
        let children = MoreJSON.stringList(store.links["children"])
        DetailSheetRow("Parents", parents.joined(separator: ", "))
        DetailSheetRow("Children", children.joined(separator: ", "))
    }

    @ViewBuilder
    private var comments: some View {
        if !store.comments.isEmpty {
            Text("Comments")
                .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                .padding(.top, 6).padding(.bottom, 6)
            ForEach(Array(store.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 0) {
                    Text(comment.author.isEmpty ? "anon" : comment.author)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JcTheme.accent)
                    Text(comment.body)
                        .font(.system(size: 14))
                        .foregroundStyle(JcTheme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
    }

    /// Post without leaving the sheet; the store reloads the detail so the new
    /// comment appears immediately.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Add a comment…", text: $draftComment, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .disabled(store.isPostingComment)
            if store.isPostingComment {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    let text = draftComment
                    Task {
                        if await store.postComment(text) { draftComment = "" }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16)).foregroundStyle(JcTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Run / Stop

    private var runControl: some View {
        Button {
            guard !store.isBusy else { return }
            Task {
                if store.isRunning { await store.stop() } else { await store.run(onRun) }
            }
        } label: {
            ZStack {
                if store.isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if store.isRunning {
                    HStack(spacing: 6) {
                        PulsingDot(color: JcTheme.danger, size: 8)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 17)).foregroundStyle(JcTheme.danger)
                        Text("Stop").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(JcTheme.danger)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17)).foregroundStyle(.white)
                        Text("Run").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if store.isRunning {
                    shape.fill(JcTheme.danger.opacity(0.15))
                        .overlay(shape.strokeBorder(JcTheme.danger.opacity(0.5), lineWidth: 1))
                } else {
                    shape.fill(JcTheme.blueGradient)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    // MARK: Worker log

    @ViewBuilder
    private var logSection: some View {
        if store.isLoadingLog {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        } else if let error = store.logError, store.log == nil {
            Text("Log error: \(error)")
                .font(.system(size: 12)).foregroundStyle(JcTheme.danger)
        } else if let log = store.log {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Worker log").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    Spacer(minLength: 0)
                    if store.isRunning {
                        PulsingDot(color: JcTheme.success, size: 6)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(JcTheme.success)
                    } else {
                        Button { Task { await store.loadLog() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ScrollView {
                    Text(log.isEmpty ? "(empty)" : log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(10)
                .background(JcTheme.surfaceAlt,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            }
        } else {
            Button { Task { await store.loadLog() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 14))
                    Text("Load worker log").font(JcText.label)
                }
                .foregroundStyle(JcTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A labelled action in the detail sheet's wrapping action row.
struct KanbanSheetAction: View {
    let symbol: String
    let label: String
    var danger: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(label).font(JcText.label)
            }
            .foregroundStyle(danger ? JcTheme.danger : JcTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// One job's detail sheet: status, prompt, the field grid, run history, and the
/// pinned 2×2 action bar (Run now / Pause-Resume / Edit / Delete).
struct CronDetailView: View {
    let job: CronJob
    @State var history: CronHistoryStore
    /// Performed by the list after this sheet dismisses.
    let onAction: (CronJobAction) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        DetailSheet(title: job.name.isEmpty ? "Task" : job.name) {
            VStack(alignment: .leading, spacing: 0) {
                StatusPill(job.statusLabel, color: Color(tone: job.statusTone),
                           live: job.isRunning)
                    .padding(.bottom, 16)
                if !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CronPromptCard(prompt: job.prompt).padding(.bottom, 18)
                }
                SectionHeader("Details")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(tiles, id: \.label) { tile in
                        CronInfoTile(symbol: tile.symbol, label: tile.label, value: tile.value)
                    }
                }
                .padding(.bottom, 10)
                SectionHeader("Run history")
                CronRunHistoryView(store: history)
            }
        } footer: {
            actionBar
        } actions: {
            EmptyView()
        }
        .task { await history.load() }
    }

    /// The non-empty fields, in the Flutter order.
    private var tiles: [(symbol: String, label: String, value: String)] {
        var out: [(String, String, String)] = [
            ("clock", "Schedule", job.schedule),
            ("arrow.right", "Next run", job.nextRunLabel()),
            ("clock.arrow.circlepath", "Last run", job.lastRunLabel()),
            ("person", "Profile", job.profile),
            (CronDeliver.iconName(job.deliver), "Deliver", CronDeliver.label(job.deliver)),
            ("memorychip", "Model", job.model),
            ("puzzlepiece", "Skills", job.skills.joined(separator: ", ")),
            ("bell", "Toasts", job.toastNotifications ? "Enabled" : "Disabled"),
        ]
        out.removeAll { $0.2.trimmingCharacters(in: .whitespaces).isEmpty }
        return out.map { (symbol: $0.0, label: $0.1, value: $0.2) }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CronActionButton(symbol: "play.fill", label: "Run now", primary: true) {
                    onAction(.run)
                }
                CronActionButton(symbol: job.isPaused ? "play.circle" : "pause.fill",
                                 label: job.isPaused ? "Resume" : "Pause") {
                    onAction(.pauseResume)
                }
            }
            HStack(spacing: 10) {
                CronActionButton(symbol: "square.and.pencil", label: "Edit") {
                    onAction(.edit)
                }
                CronActionButton(symbol: "trash", label: "Delete", danger: true) {
                    onAction(.delete)
                }
            }
        }
    }
}

/// The task's instruction, on a tinted brand card.
struct CronPromptCard: View {
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.accent)
                Text("PROMPT")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(JcTheme.accent)
            }
            Text(prompt).font(.system(size: 14)).foregroundStyle(JcTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape.fill(LinearGradient(colors: [JcTheme.accent.opacity(0.12),
                                               JcTheme.cyan.opacity(0.04)],
                                      startPoint: .leading, endPoint: .trailing))
                .overlay(shape.strokeBorder(JcTheme.accent.opacity(0.25), lineWidth: 1))
        }
    }
}

/// A labelled metric tile in the detail grid.
struct CronInfoTile: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                Text(label.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(JcTheme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

/// One button in the detail sheet's action bar.
struct CronActionButton: View {
    let symbol: String
    let label: String
    var primary: Bool = false
    var danger: Bool = false
    let action: () -> Void

    private var tint: Color { danger ? JcTheme.danger : (primary ? .white : JcTheme.text) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if primary {
                    shape.fill(JcTheme.blueGradient)
                } else {
                    shape.fill(JcTheme.glassFill)
                        .overlay(shape.strokeBorder(
                            danger ? JcTheme.danger.opacity(0.45) : JcTheme.glassBorder,
                            lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The run history list. The index loads with the sheet; each run's captured
/// output is fetched only the first time its row is expanded.
struct CronRunHistoryView: View {
    @State var store: CronHistoryStore
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isLoading {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            } else if let error = store.errorMessage {
                Text("Failed to load history: \(error)")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.danger)
            } else if store.runs.isEmpty {
                Text("No runs yet.").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            } else {
                ForEach(store.runs) { run in
                    CronRunRow(run: run,
                               isExpanded: expanded.contains(run.id),
                               isLoading: store.isLoadingOutput(run),
                               output: store.output(for: run)) {
                        if expanded.contains(run.id) {
                            expanded.remove(run.id)
                        } else {
                            expanded.insert(run.id)
                            Task { await store.loadOutput(run) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One run: a disclosure row whose body is the captured output.
struct CronRunRow: View {
    let run: CronRun
    let isExpanded: Bool
    let isLoading: Bool
    let output: String?
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.label).font(.system(size: 13)).foregroundStyle(JcTheme.text)
                        if let subtitle = run.subtitle {
                            Text(subtitle).font(.system(size: 11))
                                .foregroundStyle(JcTheme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isExpanded ? JcTheme.accent : JcTheme.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if isLoading && output == nil {
                    ProgressView().controlSize(.small).padding(8)
                } else {
                    Text((output ?? "").isEmpty ? "(no output)" : (output ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(JcTheme.surfaceAlt,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}

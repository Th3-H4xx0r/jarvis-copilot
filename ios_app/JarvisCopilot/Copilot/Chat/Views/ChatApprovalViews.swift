import SwiftUI

// MARK: - A command the turn is paused on

/// Above the composer while the turn waits on a command (tools/approval.py):
/// what it wants to run, and Deny / Always / Allow. Same glass as the send card.
struct ChatCommandApprovalBar: View {
    let request: ChatCommandApproval
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                JcIcon("hand.raised.fill", size: 14, weight: .semibold)
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(JcTheme.accent.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow this command?")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(JcTheme.text)
                    if !request.description.isEmpty {
                        Text(ApprovalText.reason(request.description))
                            .font(.footnote)
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            ApprovalCommandBox(command: request.command, maxHeight: 120)
            ApprovalButtons(canAlways: request.canAlways, isSend: false, full: true, onAnswer: onAnswer)
                .id(request.id)   // a new ask gets fresh, enabled buttons
        }
        .padding(14)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

/// The waiting approval on a running job's card.
struct HarnessJobApprovalRow: View {
    let approval: HarnessJob.Approval
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                JcIcon(approval.isSend ? "paperplane.fill" : "hand.raised.fill", size: 11, weight: .semibold)
                    .accessibilityHidden(true)
                Text(approval.isSend ? "Wants to send" : "Needs your approval")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(JcTheme.accent)
            if approval.isSend {
                let line = approval.description.isEmpty ? approval.command : approval.description
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(3)
                }
            } else {
                ApprovalCommandBox(command: approval.command, maxHeight: 80)
                if !approval.description.isEmpty {
                    Text(ApprovalText.reason(approval.description))
                        .font(.caption)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                }
            }
            ApprovalButtons(canAlways: approval.canAlways, isSend: approval.isSend, full: false, onAnswer: onAnswer)
                .id("\(approval.approvalID):\(approval.command)")
        }
        .padding(.top, 2)
    }
}

/// The command, monospaced, scrolling when long.
private struct ApprovalCommandBox: View {
    let command: String
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(command)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(JcTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
        .accessibilityLabel("Command: \(command)")
    }
}

/// Deny · (Always) · Allow — "deny" / "always" / "once" to /api/approval/respond.
private struct ApprovalButtons: View {
    let canAlways: Bool
    let isSend: Bool
    let full: Bool
    let onAnswer: (String) -> Void

    @State private var answered = false

    var body: some View {
        HStack(spacing: full ? 10 : 8) {
            button(isSend ? "Don't send" : "Deny", choice: "deny", tint: .secondary)
            if canAlways && !isSend {
                button("Always", choice: "always", tint: JcTheme.text)
            }
            button(isSend ? "Send" : "Allow", choice: "once", tint: JcTheme.accent,
                   symbol: isSend ? "paperplane.fill" : "checkmark")
        }
        .disabled(answered)
        // If the answer never lands (the request failed), the buttons come back.
        .task(id: answered) {
            guard answered else { return }
            try? await Task.sleep(for: .seconds(8))
            answered = false
        }
    }

    @ViewBuilder
    private func button(_ title: String, choice: String, tint: Color, symbol: String? = nil) -> some View {
        Button {
            answered = true
            onAnswer(choice)
        } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: full ? .infinity : nil, minHeight: full ? 24 : nil)
        }
        .buttonStyle(.jcGlass(tint: tint, compact: !full, full: full))
    }
}

enum ApprovalText {
    /// The gate's description ("recursive delete") as a sentence.
    static func reason(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }
}

// MARK: - A Background job as a conversation

/// What opens from a job card: the job in the regular chat view — the question
/// it was handed, then everything it does, live while it runs and the full
/// transcript once it ends. Read-only; Stop and any approval it waits on are
/// here too.
struct HarnessJobSheet: View {
    let chatSessionID: String
    let job: HarnessJob
    /// The chat the card is in: its live job cards and Stop.
    let parent: ChatStore

    /// Made once the sheet is up (not on every rebuild of the parent's body).
    @State private var store: ChatStore?
    @Environment(\.dismiss) private var dismiss

    /// The newest card: the chat's live events beat the view's snapshot.
    private var current: HarnessJob { parent.job(store?.jobInView ?? job) }

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    ChatConversationView(store: store, showsComposer: false) {
                        statusBar
                    }
                    .memoryChipsHidden()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle(current.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .task(id: job.id) {
            let store = self.store ?? ChatStore()
            self.store = store
            await store.openJob(chatSessionID: chatSessionID, jobID: job.id)
        }
        // The card knows the worker its approvals are answered on, even when
        // the view was opened before the job started.
        .onChange(of: current.workerSession) { _, worker in
            if !worker.isEmpty { store?.approvalSessionOverride = worker }
        }
        .presentationDragIndicator(.visible)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            JcIcon(statusIcon, size: 12, weight: .semibold)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(current.isRunning ? HarnessJobFormat.detail(current) : HarnessJobFormat.line(current))
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 6)
            if current.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(HarnessJobFormat.clock(context.date.timeIntervalSince1970 - current.startedAt))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(JcTheme.muted)
                }
                Button(current.stopping ? "Stopping…" : "Stop") {
                    Task { await parent.stopJob(current.id, in: chatSessionID) }
                }
                .buttonStyle(.jcGlass(tint: JcTheme.text, compact: true))
                .disabled(current.stopping)
                .accessibilityLabel("Stop \(current.label)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var statusIcon: String {
        switch current.status {
        case "running": return current.approval == nil ? "circle.dotted" : "hand.raised.fill"
        case "done": return "checkmark"
        case "stopped": return "stop.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch current.status {
        case "running": return JcTheme.accent
        case "done": return JcTheme.success
        case "stopped": return JcTheme.muted
        default: return JcTheme.danger
        }
    }
}

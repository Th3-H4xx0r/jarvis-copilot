import SwiftUI

/// The remote tool-permission approval surface — port of `coding/approval_card.dart`.
///
/// The push notification is the primary away-from-app path; this is the in-app
/// one, pinned above everything in the Coding tab so a verdict can be given from
/// anywhere in it. Only the FIRST pending request is shown (with a "+N" count):
/// answering it reveals the next.
struct CodingApprovalBanner: View {
    let store: CodingStore

    var body: some View {
        if let first = store.pendingApprovals.first {
            CodingApprovalCard(permission: first,
                               extra: store.pendingApprovals.count - 1) { decision, message in
                await store.respondPermission(first.requestId, decision: decision, message: message)
            }
            // Keyed on the request so answering one animates the next in rather
            // than mutating the open card's text under the user's finger.
            .id(first.requestId)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

/// One approval request: Approve / Deny / Reply-and-steer.
///
/// `respond` is awaited so the buttons can stay locked until the verdict lands —
/// on success the card is removed by the store, on failure it comes back and the
/// user can retry.
struct CodingApprovalCard: View {
    let permission: PendingPermission
    var extra: Int = 0
    let respond: (_ decision: String, _ message: String?) async -> Void

    @State private var replying = false
    @State private var reply = ""
    @State private var busy = false
    @FocusState private var replyFocused: Bool

    private var purple: Color { CodingUI.purple }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summary.padding(.top, 8)
            if replying { replyEditor.padding(.top, 10) } else { actions.padding(.top, 10) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(purple.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(purple.opacity(0.36), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(purple)
            Text("Claude needs approval")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(purple)
            Spacer(minLength: 8)
            Text(CodingUI.approvalMeta(permission, extra: extra))
                .font(.system(size: 11))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
    }

    private var summary: some View {
        Text(CodingUI.approvalSummary(permission))
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(CodingUI.paneMuted)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CodingUI.pane, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { send("deny", nil) } label: {
                Label("Deny", systemImage: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Button {
                replying = true
                replyFocused = true
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(purple)
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Reply and steer")

            Button { send("allow", nil) } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    }
                    Text("Approve").font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(CodingUI.green, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .layoutPriority(2)
        }
    }

    private var replyEditor: some View {
        VStack(spacing: 8) {
            TextField("Tell Claude what to do instead…", text: $reply, axis: .vertical)
                .lineLimit(1...3)
                .focused($replyFocused)
                .jcFieldStyle(radius: 10)
            HStack {
                Button("Cancel") { replying = false }
                    .font(JcText.label)
                    .foregroundStyle(JcTheme.muted)
                    .buttonStyle(.plain)
                    .disabled(busy)
                Spacer()
                Button { send("deny", reply) } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text("Send to Claude").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(purple, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    private func send(_ decision: String, _ message: String?) {
        guard !busy else { return }
        busy = true
        Task {
            await respond(decision, message)
            // The card is normally gone by now; unlock anyway so a failure that
            // put it back is retryable.
            busy = false
            replying = false
        }
    }
}

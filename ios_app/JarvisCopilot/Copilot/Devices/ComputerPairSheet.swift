import SwiftUI

/// What scanning a computer's "Pair with your iPhone" QR opens: "Pair <name> (Windows)?" →
/// Face ID → the code goes to the computer over the home network → "Paired <name>", or the
/// code to type on it when the phone can't reach it.
struct ComputerPairSheet: View {
    @State private var flow: ComputerPairFlow
    @Environment(\.dismiss) private var dismiss

    /// See `DevicesPage.init` — a view's `init` isn't main-actor-isolated.
    init(payload: ComputerPairPayload) {
        _flow = State(initialValue: MainActor.assumeIsolated { ComputerPairFlow(payload: payload) })
    }

    init(flow: ComputerPairFlow) {
        _flow = State(initialValue: flow)
    }

    private var payload: ComputerPairPayload { flow.payload }

    var body: some View {
        DetailSheet(title: title) {
            VStack(alignment: .leading, spacing: 14) { content }
        } actions: {
            actions
        }
        .interactiveDismissDisabled(flow.isWorking)
    }

    private var title: String {
        switch flow.phase {
        case .paired(let name): return "Paired \(name)"
        case .fallback: return "Type the code on \(payload.name)"
        default: return payload.title
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .confirm, .working, .failed:
            Text("\(payload.name) joins your Jarvis as a paired device, so Jarvis can reach it. "
               + "You confirm it's you with Face ID first.")
                .font(JcText.body)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            computerRow
            if case .working(let step) = flow.phase {
                HStack(spacing: 10) {
                    JcLoader(size: 16).foregroundStyle(JcTheme.text)
                    Text(step).font(JcText.body).foregroundStyle(JcTheme.muted)
                }
            }
            if case .failed(let message) = flow.phase {
                Text(message).font(JcText.small).foregroundStyle(JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = flow.notice {
                Text(notice).font(JcText.small).foregroundStyle(JcTheme.danger)
            }
        case .paired(let name):
            HStack(spacing: 12) {
                JcIcon("checkmark.circle.fill", size: 22).foregroundStyle(JcTheme.text)
                Text("Jarvis can reach \(name) now.")
                    .font(JcText.body).foregroundStyle(JcTheme.text)
            }
        case .fallback(let code, let error):
            Text(flow.fallbackLead ?? "")
                .font(JcText.body)
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(6)
                .foregroundStyle(JcTheme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
                .accessibilityLabel(flow.fallbackMessage ?? code)
            Text(error == nil
                 ? "Is the phone on the same Wi-Fi? If iPhone asked to find devices on your network, "
                   + "allow it and try again. The code works for ten minutes."
                 : "The code works for ten minutes.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The computer the QR named, so he can see what he's about to let in.
    private var computerRow: some View {
        HStack(spacing: 12) {
            JcIcon("desktopcomputer", size: 20).foregroundStyle(JcTheme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.name).font(JcText.body.weight(.semibold)).foregroundStyle(JcTheme.text)
                Text("\(payload.os.label) \u{00B7} \(payload.host)")
                    .font(JcText.small).foregroundStyle(JcTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch flow.phase {
        case .confirm:
            GradientButton("Pair") { Task { await flow.pair() } }
            GlassButton(title: "Cancel", ghost: true) { dismiss() }
        case .working:
            GradientButton("Pairing", busy: true)
        case .failed:
            GradientButton("Try again") { Task { await flow.pair() } }
            GlassButton(title: "Close", ghost: true) { dismiss() }
        case .paired:
            GlassButton(title: "Done", ghost: true) { dismiss() }
        case .fallback:
            if flow.canRetrySend {
                GlassButton(title: "Try again", ghost: true) {
                    Task { await flow.retrySend() }
                }
            }
            GlassButton(title: "Done", ghost: true) { dismiss() }
        }
    }
}

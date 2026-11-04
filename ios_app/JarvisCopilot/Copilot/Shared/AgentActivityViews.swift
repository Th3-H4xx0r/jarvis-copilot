import SwiftUI
import UIKit

// The per-agent Live Activity's views: the Lock Screen banner and the Dynamic
// Island's regions. Plain SwiftUI so they compile into the widget (which renders
// them through `AgentLiveActivity`) and the app (its settings rows and render
// tests).
//
// Black and white, like the system's own activities (his pick, 2026-11-03: "more
// black and white and less colorful"): the agent's logo on a quiet glass disc,
// white and grey text, the state as a word with a small dot, solid buttons —
// grey, and white with black text for the one that goes ahead. No accent, no amber.
//
// The Dynamic Island's compact / minimal slots must hold only plain shapes,
// images and text at a FIXED size. An indeterminate `ProgressView` there left the
// whole island a full-width EMPTY black bar on iOS 27 (iPhone 17 Pro Max) while
// the Lock Screen view, which has none, rendered fine — never put a spinner there.

/// Text roles on the activity's dark glass.
enum AgentLA {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
    static let well = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.1)
}

/// "Working", drawn as a still arc at a fixed size (the Jarvis voice activity's
/// coding mode uses it; an indeterminate `ProgressView` breaks the island).
struct AgentBusyRing: View {
    let color: Color
    var size: CGFloat = 16
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: max(2, size * 0.14))
            Circle().trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: max(2, size * 0.14), lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// The agent's logo on a quiet glass disc.
struct AgentLogoMark: View {
    let agent: String
    var state: String = "idle"
    var size: CGFloat = 40
    /// The disc (off in the cramped compact island: the bare mark).
    var ring: Bool = true
    /// Overrides the mark's white (amber while it waits on you, compact).
    var tint: Color? = nil
    /// Kept for callers; the state is said in words now, not with a coloured rim.
    var stateRing: Bool = true

    var body: some View {
        ZStack {
            if AgentBrand.mark(for: agent) == .orb {
                orb
            } else {
                if ring { Circle().fill(Color.white.opacity(0.12)) }
                mark.frame(width: size * (ring ? 0.5 : 0.78), height: size * (ring ? 0.5 : 0.78))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AgentBrand.title(for: agent))
    }

    @ViewBuilder private var mark: some View {
        switch AgentBrand.mark(for: agent) {
        case .asset(let name):
            Image(name).renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(tint ?? .white)
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(tint ?? .white)
        case .orb:
            EmptyView()
        }
    }

    @ViewBuilder private var orb: some View {
        if let ui = jarvisOrbUIImage {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle().fill(JcAccent.color)
        }
    }
}

/// The state as a word with a small dot: "Working", "Idle", "Failed".
struct AgentStatePill: View {
    let state: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state == "working" || state == "thinking" ? AgentLA.primary : AgentLA.tertiary)
                .frame(width: 6, height: 6)
            Text(jcAgentStateLabel(state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AgentLA.secondary)
                .lineLimit(1)
        }
        // The island's trailing slot squeezed "Working" to "…" beside the center text.
        .fixedSize()
    }
}

/// The header's text: the agent, then the lead's project, how many others, and
/// how many more wait on you.
struct AgentHeaderText: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var titleSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(st.name.isEmpty ? AgentBrand.title(for: agent) : st.name)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(AgentLA.primary)
                .lineLimit(1)
            subtitle
                .font(.system(size: titleSize - 3))
                .lineLimit(1)
        }
    }

    private var subtitle: Text {
        let moreWaiting = st.waiting - (st.waitsOnYou ? 1 : 0)
        var line = Text(st.project.isEmpty ? "Session" : st.project).foregroundColor(AgentLA.secondary)
        if st.others > 0 {
            line = line + Text(" · \(st.others) more").foregroundColor(AgentLA.secondary)
        }
        if moreWaiting > 0 {
            line = line + Text(" · \(moreWaiting) waiting").foregroundColor(AgentLA.primary)
        }
        return line
    }
}

/// What the lead is doing, with its turn timer (or how long it's been idle).
struct AgentDetailRow: View {
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Text(st.step.isEmpty ? placeholder : st.step)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(st.step.isEmpty ? AgentLA.tertiary : AgentLA.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            clock
        }
    }

    private var placeholder: String {
        st.waitsOnYou ? "Waiting on you" : (st.isWorking ? "Working" : "Ready for the next prompt")
    }

    @ViewBuilder private var clock: some View {
        if st.isWorking && st.since > 0 {
            Text(Date(timeIntervalSince1970: st.since), style: .timer)
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(AgentLA.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 56, alignment: .trailing)
        } else if !st.isWorking && !st.waitsOnYou && st.last > 0 {
            Text(Date(timeIntervalSince1970: st.last), style: .relative)
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(AgentLA.tertiary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 96, alignment: .trailing)
        }
    }
}

/// Deny / Allow for a request the phone can answer (no unlock needed), or
/// the button to answer a question in the app.
struct AgentActionsRow: View {
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        if st.showsButtons || st.showsOptions || (st.kind == "question" && st.actions) {
            AgentWaitingButtons(st: st, height: 36)
        }
    }
}

/// The Lock Screen / banner presentation.
struct AgentLockScreenView: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        // iOS cuts a Lock Screen activity off at 160 pt: the waiting card is
        // budgeted to ≤ 152 (14 + 26 + 8 + two lines + 8 + 34 + 18).
        Group {
            if st.waitsOnYou {
                AgentWaitingView(agent: agent, st: st)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            } else {
                working.padding(.vertical, 16)
            }
        }
        .padding(.horizontal, 20)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentLogoMark(agent: agent, state: st.state, size: 36)
                AgentHeaderText(agent: agent, st: st, titleSize: 15)
                Spacer(minLength: 8)
                AgentStatePill(state: st.state)
            }
            AgentDetailRow(st: st)
            AgentActionsRow(st: st)
        }
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the logo. (Beside the camera there's no room for the
/// name: it read "Claude…" in the simulator; the name goes in `.center`.)
struct AgentIslandLeading: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentLogoMark(agent: agent, state: st.state, size: 32)
            .padding(.leading, 4)
    }
}

/// Expanded, center (under the camera): "Claude Code · jarvis-copilot".
struct AgentIslandCenter: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentWaitingWho(agent: agent, st: st, nameSize: 14, oneLine: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Expanded, trailing: the state, or how long it has waited on you.
struct AgentIslandTrailing: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        Group {
            if st.waitsOnYou {
                AgentWaitingBadge(st: st, label: false)
            } else {
                AgentStatePill(state: st.state)
            }
        }
        .padding(.trailing, 4)
    }
}

/// Expanded, bottom: what the lead is doing, and its buttons.
struct AgentIslandBottom: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        Group {
            if st.waitsOnYou {
                // The expanded island stops at ~144 pt: one line of command, 36 pt buttons.
                VStack(alignment: .leading, spacing: 8) {
                    AgentWaitingMessage(st: st, size: 15, commandLines: 1)
                    AgentWaitingButtons(st: st, height: 36)
                }
                .padding(.top, 2)
                .padding(.bottom, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AgentDetailRow(st: st)
                    AgentActionsRow(st: st)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Collapsed, leading: just the logo.
struct AgentCompactLeading: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentLogoMark(agent: agent, state: st.state, size: 22, ring: false)
            .frame(width: 24, height: 24)
    }
}

/// Collapsed, trailing: how long it has waited or worked, or how it ended.
struct AgentCompactTrailing: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        Group {
            if st.waitsOnYou {
                timer(from: st.waitingStart, color: AgentLA.primary)
            } else if st.isWorking && st.since > 0 {
                timer(from: st.since, color: AgentLA.primary)
            } else if st.isWorking {
                Circle().fill(AgentLA.primary).frame(width: 7, height: 7)
            } else if st.state == "error" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentLA.primary)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentLA.secondary)
            }
        }
        .frame(width: 44, alignment: .trailing)
    }

    private func timer(from start: Double, color: Color) -> some View {
        Text(Date(timeIntervalSince1970: start), style: .timer)
            .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Minimal (another activity holds the island): the logo.
struct AgentMinimal: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentLogoMark(agent: agent, state: st.state, size: 22, ring: false)
            .frame(width: 24, height: 24)
    }
}


// MARK: - Waiting on you

/// "Waiting on you" on the Lock Screen: who asks (logo, "agent · project") and
/// how long it has waited, then what it wants — the command in a dark well, or
/// the question — then the buttons. The update that brings this on
/// carries an alert, so the island pops open on it with a sound; the expanded
/// island lays the same parts around the camera. No Face ID (`AgentLiveIntents`).
struct AgentWaitingView: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var logoSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                AgentLogoMark(agent: agent, state: st.state, size: logoSize)
                AgentWaitingWho(agent: agent, st: st, nameSize: 15, oneLine: true)
                Spacer(minLength: 8)
                AgentWaitingBadge(st: st)
            }
            AgentWaitingMessage(st: st, size: 15)
            AgentWaitingButtons(st: st, height: 34)
                .padding(.top, 2)
        }
    }
}

/// The agent, and the project under it.
struct AgentWaitingWho: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var nameSize: CGFloat = 16
    /// "Claude Code · jarvis-copilot" on one line (the Lock Screen's height budget).
    var oneLine = false

    var body: some View {
        if oneLine {
            (Text(st.name.isEmpty ? AgentBrand.title(for: agent) : st.name)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundColor(AgentLA.primary)
             + Text(st.project.isEmpty ? "" : " · \(st.project)")
                .font(.system(size: nameSize - 2))
                .foregroundColor(AgentLA.secondary))
                .lineLimit(1)
        } else {
            twoLines
        }
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(st.name.isEmpty ? AgentBrand.title(for: agent) : st.name)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundStyle(AgentLA.primary)
                .lineLimit(1)
            if !st.project.isEmpty {
                Text(st.project)
                    .font(.system(size: nameSize - 3))
                    .foregroundStyle(AgentLA.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// "Waiting 0:13": how long it has waited on you, counting up.
struct AgentWaitingBadge: View {
    let st: AgentActivityAttributes.ContentState
    /// The word before the timer (the island's camera row has room for the timer only).
    var label = true

    var body: some View {
        HStack(spacing: 4) {
            if label {
                Text("Waiting")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentLA.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // A timer Text takes all the width it's offered — pin it.
            Text(Date(timeIntervalSince1970: st.waitingStart), style: .timer)
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(AgentLA.primary)
        }
    }
}

/// What it asks: the question, or the command it wants to run (without the
/// engine's "Needs approval:" prefix) in mono on a dark well, its tool ("Bash")
/// in grey before it.
struct AgentWaitingMessage: View {
    let st: AgentActivityAttributes.ContentState
    var size: CGFloat = 15
    var commandLines = 2

    var body: some View {
        if let request = commandRequest {
            (Text(request.tool.isEmpty ? "" : "\(request.tool)  ").foregroundColor(AgentLA.secondary)
             + Text(request.command).foregroundColor(AgentLA.primary))
                .font(.system(size: size - 2, design: .monospaced))
                .lineLimit(commandLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentLA.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AgentLA.hairline, lineWidth: 0.5))
        } else {
            Text(text)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(AgentLA.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Bash: rm -rf build" → ("Bash", "rm -rf build"); a bare command keeps an empty tool.
    private var commandRequest: (tool: String, command: String)? {
        guard st.question.isEmpty, st.kind == "approval", !command.isEmpty else { return nil }
        if let colon = command.range(of: ": ") {
            let tool = String(command[..<colon.lowerBound])
            let rest = String(command[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !tool.isEmpty, tool.count <= 24, !tool.contains(" "), !rest.isEmpty { return (tool, rest) }
        }
        return ("", command)
    }

    private var command: String {
        var what = st.step
        if what.lowercased().hasPrefix("needs approval:") {
            what = String(what.dropFirst("needs approval:".count)).trimmingCharacters(in: .whitespaces)
        }
        return what
    }

    private var text: String {
        if !st.question.isEmpty { return st.question }
        return st.kind == "question" || st.state == "question" ? "It has a question for you" : "It needs your OK to go on"
    }
}

/// Deny / Allow, a question's options, or one Answer button that opens Jarvis.
struct AgentWaitingButtons: View {
    let st: AgentActivityAttributes.ContentState
    var height: CGFloat = 44

    var body: some View {
        if st.showsButtons {
            HStack(spacing: 10) {
                Button(intent: AgentDenyIntent(fingerprint: st.fingerprint)) {
                    AgentGlassButtonLabel(text: "Deny", height: height)
                }
                .buttonStyle(.plain)
                Button(intent: AgentAllowIntent(fingerprint: st.fingerprint)) {
                    AgentGlassButtonLabel(text: "Allow", tint: .white, height: height)
                }
                .buttonStyle(.plain)
            }
        } else if st.showsOptions {
            HStack(spacing: 10) {
                ForEach(Array(st.options.prefix(3).enumerated()), id: \.offset) { _, option in
                    Button(intent: AgentAnswerIntent(fingerprint: st.fingerprint,
                                                     question: st.question, option: option)) {
                        AgentGlassButtonLabel(text: option, height: height)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if st.kind == "question" || st.state == "question" {
            Link(destination: jcAgentWidgetURL(st)) {
                AgentGlassButtonLabel(text: "Answer in Jarvis", tint: .white, height: height)
            }
        }
    }
}

/// A Live Activity button, drawn the way the system draws its own (a call's
/// Decline / Accept, a timer's Pause): a solid capsule. Nil `tint` is the grey
/// button with white text; a tint (white, for the action that goes ahead) fills
/// it, with black text.
struct AgentGlassButtonLabel: View {
    let text: String
    var tint: Color? = nil
    var height: CGFloat = 44

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.white : Color.black)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(tint ?? Color.white.opacity(0.16)))
    }
}

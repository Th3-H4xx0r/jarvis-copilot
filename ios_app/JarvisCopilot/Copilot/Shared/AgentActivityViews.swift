import SwiftUI
import UIKit

// The per-agent Live Activity's views: the Lock Screen banner and the Dynamic
// Island's regions. Plain SwiftUI so they compile into the widget (which renders
// them through `AgentLiveActivity`) and the app (its settings rows and render
// tests).
//
// The Dynamic Island's compact / minimal slots must hold only plain shapes,
// images and text at a FIXED size. An indeterminate `ProgressView` there left the
// whole island a full-width EMPTY black bar on iOS 27 (iPhone 17 Pro Max) while
// the Lock Screen view, which has none, rendered fine — so "busy" is the static
// `AgentBusyRing` below, never a spinner.

/// "Working", drawn as a still arc — the island's compact slots can't host an
/// indeterminate `ProgressView` (see above). Fixed size, so it can never claim
/// the slot's full width.
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

/// The agent's logo on a glass disc, ringed in its state colour.
struct AgentLogoMark: View {
    let agent: String
    var state: String = "idle"
    var size: CGFloat = 40
    /// The state ring (off in the cramped compact island).
    var ring: Bool = true
    /// Overrides the mark's white (amber while it waits on you, compact).
    var tint: Color? = nil

    var body: some View {
        ZStack {
            if AgentBrand.mark(for: agent) == .orb {
                orb
            } else {
                Circle().fill(Color.white.opacity(ring ? 0.10 : 0))
                mark.frame(width: size * (ring ? 0.52 : 0.78), height: size * (ring ? 0.52 : 0.78))
            }
            if ring {
                Circle().strokeBorder(jcAgentStateColor(state).opacity(state == "idle" ? 0.45 : 0.95),
                                      lineWidth: max(1.5, size * 0.055))
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
                .frame(width: size * (ring ? 0.84 : 1), height: size * (ring ? 0.84 : 1))
                .clipShape(Circle())
        } else {
            Circle().fill(JcAccent.color)
                .frame(width: size * 0.84, height: size * 0.84)
        }
    }
}

/// The state, as a tinted capsule: `NEEDS YOU` in amber, `WORKING` in the accent.
struct AgentStatePill: View {
    let state: String
    var body: some View {
        let c = jcAgentStateColor(state)
        Text(jcAgentStateLabel(state).uppercased())
            .font(.system(size: 10, weight: .heavy)).tracking(0.9)
            .foregroundStyle(c)
            .lineLimit(1)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(Capsule().fill(c.opacity(0.2)))
            .overlay(Capsule().strokeBorder(c.opacity(0.45), lineWidth: 1))
    }
}

/// One small capsule per session, most urgent first — the whole group at a glance.
struct AgentFleetBar: View {
    let states: [String]
    var segment: CGSize = CGSize(width: 10, height: 4)
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Capsule().fill(jcAgentBarColor(s))
                    .frame(width: segment.width, height: segment.height)
            }
        }
    }
}

/// The header's text: the agent, then the lead's project, how many others, and
/// how many more wait on you.
struct AgentHeaderText: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var titleSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(st.name.isEmpty ? AgentBrand.title(for: agent) : st.name)
                .font(.system(size: titleSize, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
            subtitle
                .font(.system(size: titleSize - 5, weight: .semibold))
                .lineLimit(1)
        }
    }

    private var subtitle: Text {
        let moreWaiting = st.waiting - (st.waitsOnYou ? 1 : 0)
        var line = Text(st.project.isEmpty ? "session" : st.project)
            .foregroundColor(.white.opacity(0.62))
        if st.others > 0 {
            line = line + Text(" · +\(st.others) more").foregroundColor(.white.opacity(0.45))
        }
        if moreWaiting > 0 {
            line = line + Text(" · \(moreWaiting) waiting").foregroundColor(JcState.amber)
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(st.step.isEmpty ? 0.45 : 0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            clock
        }
    }

    private var placeholder: String {
        st.waitsOnYou ? "Waiting on you" : (st.isWorking ? "Working…" : "Ready for the next prompt")
    }

    @ViewBuilder private var clock: some View {
        if st.isWorking && st.since > 0 {
            Text(Date(timeIntervalSince1970: st.since), style: .timer)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 56, alignment: .trailing)
        } else if !st.isWorking && !st.waitsOnYou && st.last > 0 {
            Text(Date(timeIntervalSince1970: st.last), style: .relative)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 84, alignment: .trailing)
        }
    }
}

/// Deny / Allow for a request the phone can answer (Allow asks to unlock), or
/// the nudge to answer a question in the app.
struct AgentActionsRow: View {
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        if st.showsButtons {
            HStack(spacing: 8) {
                Button(intent: AgentDenyIntent(fingerprint: st.fingerprint)) {
                    Text("Deny").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(JcState.danger.opacity(0.85))
                Button(intent: AgentAllowIntent(fingerprint: st.fingerprint)) {
                    Text("Allow").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(JcAccent.deep)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        } else if st.kind == "question" && st.actions {
            Text("Tap to answer in Jarvis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JcState.amber)
        }
    }
}

/// The Lock Screen / banner presentation.
struct AgentLockScreenView: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        if st.waitsOnYou {
            AgentWaitingView(agent: agent, st: st, logoSize: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
        } else {
            working
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AgentLogoMark(agent: agent, state: st.state, size: 44)
                AgentHeaderText(agent: agent, st: st)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    AgentStatePill(state: st.state)
                    if st.count > 1 { AgentFleetBar(states: st.barStates) }
                }
            }
            AgentDetailRow(st: st)
            AgentActionsRow(st: st)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the logo with the agent and project beside it.
struct AgentIslandLeading: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        if st.waitsOnYou {
            // Waiting: the logo alone; the headline sits in the center region.
            AgentLogoMark(agent: agent, state: st.state, size: 40).padding(.leading, 4)
        } else {
            HStack(spacing: 9) {
                AgentLogoMark(agent: agent, state: st.state, size: 38)
                AgentHeaderText(agent: agent, st: st, titleSize: 14)
            }
            .padding(.leading, 4)
        }
    }
}

/// Expanded, trailing: the state and the fleet bar.
struct AgentIslandTrailing: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        if !st.waitsOnYou {
            VStack(alignment: .trailing, spacing: 6) {
                AgentStatePill(state: st.state)
                if st.count > 1 { AgentFleetBar(states: st.barStates) }
            }
            .padding(.trailing, 4)
        }
    }
}

/// Expanded, bottom: what the lead is doing, and its buttons.
struct AgentIslandBottom: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        Group {
            if st.waitsOnYou {
                AgentWaitingButtons(st: st)
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

/// Collapsed, leading: just the logo — amber while it waits on you.
struct AgentCompactLeading: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentLogoMark(agent: agent, state: st.state, size: 22, ring: false,
                      tint: st.waitsOnYou ? JcState.amber : nil)
            .frame(width: 24, height: 24)
    }
}

/// Collapsed, trailing: the state at a glance, and the session count when > 1.
struct AgentCompactTrailing: View {
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 5) {
            glyph.frame(width: 18, height: 18)
            if st.count > 1 {
                Text("\(min(st.count, 99))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var glyph: some View {
        if st.waitsOnYou {
            Image(systemName: st.state == "question" ? "questionmark.bubble.fill" : "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JcState.amber)
        } else if st.isWorking {
            AgentBusyRing(color: JcAccent.color, size: 15)
        } else if st.state == "error" {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JcState.danger)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(jcAgentStateColor("idle"))
        }
    }
}

/// Minimal (another activity holds the island): the logo inside its state ring.
struct AgentMinimal: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentLogoMark(agent: agent, state: st.state, size: 24,
                      tint: st.waitsOnYou ? JcState.amber : nil)
            .frame(width: 24, height: 24)
    }
}


// MARK: - Waiting on you

/// "Needs you": the agent's logo, "<Agent> waiting for your OK · 0:13" in amber
/// (counting up from when it started waiting), what it wants, and big Deny /
/// Allow buttons — or, for a question, its options (else one Answer button).
/// The update that brings this on carries an alert, so the island pops open on
/// it with a sound. The buttons ask for no Face ID (`AgentLiveIntents`).
struct AgentWaitingView: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var logoSize: CGFloat = 44
    /// The expanded island draws the logo in its own region.
    var showsLogo = true

    static let denyFill = Color(red: 0.50, green: 0.11, blue: 0.13)
    static let allowFill = Color(red: 0.19, green: 0.66, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                if showsLogo { AgentLogoMark(agent: agent, state: st.state, size: logoSize) }
                AgentWaitingHeadline(agent: agent, st: st)
            }
            AgentWaitingButtons(st: st)
        }
    }
}

/// The amber headline and, under it, what the agent is asking.
struct AgentWaitingHeadline: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("\(name) \(st.kind == "question" || st.state == "question" ? "has a question" : "waiting for your OK") · ")
                + Text(Date(timeIntervalSince1970: st.waitingStart), style: .timer))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(JcState.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
        }
    }

    private var name: String { st.name.isEmpty ? AgentBrand.title(for: agent) : st.name }

    /// The project, then the command (without the engine's "Needs approval:"
    /// prefix) or the question.
    private var detail: String {
        var what = st.question.isEmpty ? st.step : st.question
        if what.lowercased().hasPrefix("needs approval:") {
            what = String(what.dropFirst("needs approval:".count)).trimmingCharacters(in: .whitespaces)
        }
        let project = st.project.isEmpty ? "" : st.project
        if what.isEmpty { return project }
        return project.isEmpty ? what : "\(project) · \(what)"
    }
}

/// Deny / Allow, a question's options, or one Answer button that opens Jarvis.
struct AgentWaitingButtons: View {
    let st: AgentActivityAttributes.ContentState

    var body: some View {
        if st.showsButtons {
            HStack(spacing: 10) {
                Button(intent: AgentDenyIntent(fingerprint: st.fingerprint)) {
                    label("Deny", fill: AgentWaitingView.denyFill)
                }
                .buttonStyle(.plain)
                Button(intent: AgentAllowIntent(fingerprint: st.fingerprint)) {
                    label("Allow", fill: AgentWaitingView.allowFill)
                }
                .buttonStyle(.plain)
            }
        } else if st.showsOptions {
            HStack(spacing: 8) {
                ForEach(Array(st.options.prefix(3).enumerated()), id: \.offset) { _, option in
                    Button(intent: AgentAnswerIntent(fingerprint: st.fingerprint,
                                                     question: st.question, option: option)) {
                        label(option, fill: Color.white.opacity(0.16))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if st.kind == "question" || st.state == "question" {
            Link(destination: jcAgentWidgetURL(st)) {
                label("Answer", fill: JcAccent.deep)
            }
        }
    }

    private func label(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
    }
}

/// Expanded island, center (under the camera) while it waits: the headline.
struct AgentIslandWaitingCenter: View {
    let agent: String
    let st: AgentActivityAttributes.ContentState
    var body: some View {
        AgentWaitingHeadline(agent: agent, st: st)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

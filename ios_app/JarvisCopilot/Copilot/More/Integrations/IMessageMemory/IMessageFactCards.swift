import SwiftUI
import UIKit

/// The memory deck at the top of the Chat home — nothing at all while none wait.
/// One fact in front, the rest stacked behind it; Save / Skip (or swipe right /
/// left) moves to the next. A header counts them and offers Save all / Skip all.
struct IMessageFactCards: View {
    let store: IMessageFactsStore

    var body: some View {
        if let front = store.facts.first {
            VStack(alignment: .leading, spacing: 10) {
                header
                IMessageFactDeck(front: front, behind: min(store.facts.count - 1, 2)) { keep in
                    Task { await store.decide(front, store: keep) }
                }
                .id(front.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                        removal: .opacity))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .animation(.snappy, value: store.facts)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Memories to review")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(JcTheme.muted)
            if store.facts.count > 1 {
                Text("\(store.facts.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(JcTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(JcTheme.accent.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 0)
            if store.facts.count > 1 {
                Menu {
                    Button {
                        decideAll(true)
                    } label: { Label("Save all \(store.facts.count)", systemImage: "checkmark.circle") }
                    Button(role: .destructive) {
                        decideAll(false)
                    } label: { Label("Skip all \(store.facts.count)", systemImage: "xmark.circle") }
                } label: {
                    JcIcon("ellipsis", size: 14)
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Save or skip all memories")
            }
        }
        .padding(.horizontal, 4)
    }

    private func decideAll(_ keep: Bool) {
        let all = store.facts
        Task { for fact in all { await store.decide(fact, store: keep) } }
    }
}

/// The front card plus up to two cards' edges peeking out below it. The edges
/// are drawn as the front card's background, so they always match its size.
struct IMessageFactDeck: View {
    let front: IMessageFact
    /// How many cards show behind (0–2).
    let behind: Int
    var now: Date = Date()
    let onDecide: (Bool) -> Void

    private static let peek: CGFloat = 7

    var body: some View {
        IMessageFactCard(fact: front, onDecide: onDecide, now: now)
            .background {
                ZStack {
                    ForEach((0..<behind).reversed(), id: \.self) { depth in
                        let step = CGFloat(depth + 1)
                        RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                            .fill(JcTheme.surfaceAlt)
                            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                            .padding(.horizontal, 12 * step)
                            .offset(y: Self.peek * step)
                            .opacity(1 - 0.3 * step)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.bottom, CGFloat(behind) * Self.peek)
    }
}

/// One memory Jarvis wants to keep: the fact, who it came from, when it saves
/// itself, and Save / Skip. Swipe right to save, left to skip.
struct IMessageFactCard: View {
    let fact: IMessageFact
    /// true = Save, false = Skip.
    let onDecide: (Bool) -> Void
    var now: Date = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    private static let decideAt: CGFloat = 110
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            Text(fact.fact)
                .font(.body.weight(.semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            sourceRow
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
            actions
        }
        .padding(16)
        .background {
            shape.fill(JcTheme.surface)
                .overlay(shape.fill(LinearGradient(colors: [JcTheme.accent.opacity(0.10), .clear],
                                                   startPoint: .top, endPoint: .center)))
        }
        .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .overlay(alignment: drag > 0 ? .topLeading : .topTrailing) { swipeHint }
        .offset(x: drag)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag / 28)), anchor: .bottom)
        .gesture(swipe)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Save") { onDecide(true) }
        .accessibilityAction(named: "Skip") { onDecide(false) }
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack(spacing: 8) {
            JcIcon("sparkles", size: 12)
                .foregroundStyle(JcTheme.accent)
                .frame(width: 24, height: 24)
                .background(JcTheme.accent.opacity(0.16), in: Circle())
            Text("New memory")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(JcTheme.accent)
            Spacer(minLength: 8)
            if let left = savesIn {
                HStack(spacing: 4) {
                    JcIcon("clock", size: 10)
                    Text(left)
                }
                .font(.caption)
                .foregroundStyle(JcTheme.muted)
            }
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            avatar
            Text(sourceText)
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
    }

    private var avatar: some View {
        Group {
            if IMessageFactCard.isGroup(fact.chatName) {
                JcIcon("person.2.fill", size: 10)
            } else {
                Text(IMessageFactCard.initials(fact.chatName))
                    .font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(JcTheme.text)
        .frame(width: 24, height: 24)
        .background(JcTheme.surfaceAlt, in: Circle())
        .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text("Swipe right to save")
                .font(.caption)
                .foregroundStyle(JcTheme.muted.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            Button("Skip") { onDecide(false) }
                .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
            Button {
                onDecide(true)
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
        }
    }

    @ViewBuilder private var swipeHint: some View {
        let progress = min(1, abs(drag) / Self.decideAt)
        if drag != 0 {
            Text(drag > 0 ? "SAVE" : "SKIP")
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(drag > 0 ? JcTheme.accent : JcTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(drag > 0 ? JcTheme.accent : JcTheme.muted, lineWidth: 1.5))
                .padding(14)
                .opacity(progress)
                .accessibilityHidden(true)
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Horizontal only, so the chat underneath still scrolls.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let crossed = abs(drag) < Self.decideAt && abs(value.translation.width) >= Self.decideAt
                drag = value.translation.width
                if crossed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            .onEnded { value in
                if abs(value.translation.width) >= Self.decideAt {
                    let keep = value.translation.width > 0
                    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.18)) { drag = keep ? 520 : -520 }
                    onDecide(keep)
                } else {
                    withAnimation(.snappy) { drag = 0 }
                }
            }
    }

    // MARK: Text

    /// "Saves in 18 h" / "Saves in 40 min" — nil when the server didn't say.
    var savesIn: String? {
        guard fact.expiresAt > 0 else { return nil }
        let left = fact.expiresAt - now.timeIntervalSince1970
        if left <= 60 { return "Saving soon" }
        if left < 3600 { return "Saves in \(Int(left / 60)) min" }
        return "Saves in \(Int((left / 3600).rounded())) h"
    }

    var sourceText: String {
        let who = IMessageFactCard.displayName(fact.chatName)
        let when = IMessageFact.relative(fact.date, now: now)
        return who.isEmpty ? when : "\(who) · \(when)"
    }

    private var accessibilityText: String {
        [ "New memory: \(fact.fact)", sourceText, savesIn ].compactMap { $0 }.joined(separator: ". ")
    }

    /// The server names a group chat "the group “F1”".
    static func isGroup(_ chatName: String) -> Bool {
        chatName.lowercased().hasPrefix("the group ")
    }

    static func displayName(_ chatName: String) -> String {
        var name = chatName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGroup(name) {
            name = String(name.dropFirst("the group ".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "“”\" "))
        }
        return name
    }

    static func initials(_ chatName: String) -> String {
        let words = displayName(chatName).split(whereSeparator: { $0 == " " || $0 == "," })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

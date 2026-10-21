import SwiftUI

/// The fact cards at the top of the Chat home — nothing at all while none wait.
/// Two show; the rest fold into an "N more" row.
struct IMessageFactCards: View {
    let store: IMessageFactsStore

    @State private var expanded = false

    static let collapsedCount = 2
    /// Unfolded, a long list scrolls inside this instead of taking the whole chat.
    static let expandedMaxHeight: CGFloat = 360

    var body: some View {
        if !store.facts.isEmpty {
            let hidden = max(0, store.facts.count - Self.collapsedCount)
            VStack(spacing: 8) {
                if expanded {
                    ViewThatFits(in: .vertical) {
                        cards(store.facts)
                        ScrollView { cards(store.facts) }
                    }
                    .frame(maxHeight: Self.expandedMaxHeight)
                } else {
                    cards(Array(store.facts.prefix(Self.collapsedCount)))
                }
                if hidden > 0 {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(expanded ? "Show less" : "\(hidden) more")
                                .font(.system(size: 13, weight: .semibold))
                            JcIcon(expanded ? "chevron.up" : "chevron.down", size: 11)
                        }
                        .foregroundStyle(JcTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Show fewer facts" : "\(hidden) more facts")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .animation(.snappy, value: store.facts)
            .onChange(of: hidden) { _, left in if left == 0 { expanded = false } }
        }
    }

    private func cards(_ facts: [IMessageFact]) -> some View {
        VStack(spacing: 8) {
            ForEach(facts) { fact in
                IMessageFactCard(fact: fact) { keep in
                    Task { await store.decide(fact, store: keep) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// One fact: what Jarvis wants to remember, where it came from, Store / Skip.
/// The Agents approval card's look, smaller.
struct IMessageFactCard: View {
    let fact: IMessageFact
    /// true = Store, false = Skip.
    let onDecide: (Bool) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                JcIcon("bubble.left", size: 13)
                    .foregroundStyle(JcTheme.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.fact)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(fact.source())
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Button("Store") { onDecide(true) }
                    .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true, full: true))
                    .accessibilityLabel("Store this fact")
                Button("Skip") { onDecide(false) }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true, full: true))
                    .accessibilityLabel("Skip this fact")
            }
        }
        .padding(12)
        .background(JcTheme.surface, in: shape)
        .overlay(shape.strokeBorder(JcTheme.accent.opacity(0.35), lineWidth: 1))
    }
}

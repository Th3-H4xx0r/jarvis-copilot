import SwiftUI

/// The "Quota & Usage" card, ported from `widgets/quota_card.dart`.
///
/// One block per configured quota-capable provider (Claude Code, Codex, …), each
/// limit window drawn as a bar + percentage + reset countdown. It sits at the top
/// of Insights; the Flutter client also showed it in Settings, which here is
/// another area's screen — drop this view in when that screen wants it.
struct QuotaCard: View {
    @State private var store: QuotaStore

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: QuotaStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { QuotaStore() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GlassCard(padding: 16) { body(for: store.providers) }
        }
        .task {
            // The card lives inside a tab that stays alive; only load once.
            if store.isLoading && store.providers.isEmpty { store.load() }
        }
    }

    private var header: some View {
        HStack {
            Text("Quota & Usage")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(JcTheme.text)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small).tint(JcTheme.muted)
            } else {
                Button { store.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh usage")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func body(for providers: [QuotaProvider]) -> some View {
        if store.isLoading {
            ProgressView().controlSize(.small).tint(JcTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else if store.showsRetry {
            note(store.errorMessage ?? "Couldn’t load usage", retry: { store.reload() })
        } else if providers.isEmpty {
            note(store.emptyText, retry: nil)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        Rectangle().fill(JcTheme.glassBorder)
                            .frame(height: 1)
                            .padding(.vertical, 14)
                    }
                    QuotaProviderBlock(provider: provider)
                }
            }
        }
    }

    private func note(_ text: String, retry: (() -> Void)?) -> some View {
        HStack {
            Text(text).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
                    .font(JcText.label)
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .padding(.vertical, 8)
    }
}

/// One provider: badge + name (+ plan), its windows, then any free-text details.
struct QuotaProviderBlock: View {
    let provider: QuotaProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: provider.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(JcTheme.text)
                    .frame(width: 30, height: 30)
                    .background(JcTheme.text.opacity(0.10), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                Text(provider.headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Spacer(minLength: 0)
            }
            if provider.windows.isEmpty {
                Text("No active limits.")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            ForEach(provider.windows) { window in
                QuotaWindowRow(window: window)
            }
            ForEach(provider.details, id: \.self) { detail in
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One limit window: label + percent, the bar, then "resets in … · detail".
struct QuotaWindowRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                Spacer(minLength: 8)
                Text(window.percentText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(JcTheme.text)
            }
            QuotaBar(fraction: window.barFraction, tone: window.barTone)
            let subtitle = window.subtitle()
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

/// A 6pt usage bar whose fill tracks the window's used fraction and whose colour
/// shifts amber/red near the limit. An unknown value renders an empty track
/// (paired with "—") rather than a misleading full or empty bar.
struct QuotaBar: View {
    let fraction: Double
    let tone: QuotaBarTone

    private var colors: [Color] {
        switch tone {
        case .critical: return [Color(jcHex: 0xEF4444), Color(jcHex: 0xF97316)]
        case .warning:  return [Color(jcHex: 0xF59E0B), Color(jcHex: 0xFBBF24)]
        case .normal:   return [JcTheme.cyan, JcTheme.accent]
        case .unknown:  return [JcTheme.muted, JcTheme.muted]
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(JcTheme.glassBorder)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

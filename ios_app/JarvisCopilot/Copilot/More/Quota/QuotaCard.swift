import SwiftUI

/// The "Quota & usage" card at the top of Insights.
///
/// One block per configured quota-capable provider (Claude Code, Codex, …), each
/// limit window drawn as a bar + percentage + reset countdown.
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

    /// The app's section label, with the refresh in its trailing slot.
    private var header: some View {
        JcSectionLabel("Quota & usage", first: true) {
            if store.isRefreshing {
                JcLoader(size: 12).foregroundStyle(JcTheme.muted)
            } else {
                Button { store.reload() } label: {
                    JcIcon("arrow.clockwise", size: 13)
                        .foregroundStyle(JcTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh usage")
            }
        }
    }

    @ViewBuilder
    private func body(for providers: [QuotaProvider]) -> some View {
        if store.isLoading {
            JcLoader(size: 16).foregroundStyle(JcTheme.muted)
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
            if let retry { JcSmallAction("Retry", action: retry) }
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
                JcIconSquare(symbol: provider.iconName)
                Text(provider.headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Spacer(minLength: 0)
            }
            if provider.windows.isEmpty {
                Text("No active limits")
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
                    .font(.system(size: 13, weight: .semibold))
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
/// turns amber, then red, near the limit. An unknown value renders an empty track
/// (paired with "—") rather than a misleading full or empty bar.
struct QuotaBar: View {
    let fraction: Double
    let tone: QuotaBarTone

    private var color: Color {
        switch tone {
        case .critical: return JcTheme.danger
        case .warning:  return JcTheme.amber
        case .normal:   return JcTheme.accent
        case .unknown:  return JcTheme.muted
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(JcTheme.glassBorder)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

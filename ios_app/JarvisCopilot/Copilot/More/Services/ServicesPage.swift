import SwiftUI

/// Where the Services screens push, inside More's stack.
enum ServicesRoute: Hashable {
    case detail(String)
    case keys(ServiceKeysScope)
}

/// Services: one card per connected service (Stripe, GitHub, Vercel, n8n,
/// Notion, Cal.com, Resend), coloured by its state, saying why. Live while on
/// screen from the `services` topic; tap a card for figures, lists and actions.
struct ServicesPage: View {
    var store: ServicesStore = .shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                if let error = store.loadError, store.services.isEmpty {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
                ForEach(store.services) { snapshot in
                    NavigationLink(value: ServicesRoute.detail(snapshot.id)) {
                        ServiceCard(snapshot: snapshot)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(store.pendingNames, id: \.id) { pending in
                    PendingServiceCard(name: pending.name)
                }
                if store.loaded && store.services.isEmpty && store.pending.isEmpty && store.loadError == nil {
                    emptyState
                }
                if !store.unconfigured.isEmpty && !(store.services.isEmpty && store.pending.isEmpty) {
                    connectMore
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .refreshable { await store.refresh() }
        .jcScreen("Services")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ServicesRoute.keys(.services(nil))) {
                    JcIcon("key", size: 17)
                }
                .accessibilityLabel("Keys and settings")
            }
        }
        .navigationDestination(for: ServicesRoute.self) { route in
            switch route {
            case .detail(let id):
                ServiceDetailScreen(serviceID: id, store: store)
            case .keys(let scope):
                ServiceKeysScreen(scope: scope, store: store)
            }
        }
        .task { if store.config == nil { await store.loadConfig() } }
        .servicesVisibility { store.setVisible($0, feed: .services, owner: "services-page") }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3.5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text(countLine)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
            }
            Spacer()
            HStack(spacing: 12) {
                toneCount(.error)
                toneCount(.warning)
                toneCount(.ok)
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private func count(_ tone: ServiceTone) -> Int {
        store.services.filter { $0.tone == tone }.count
    }

    @ViewBuilder private func toneCount(_ tone: ServiceTone) -> some View {
        let n = count(tone)
        if n > 0 {
            HStack(spacing: 5) {
                Circle().fill(ServicesStyle.color(tone)).frame(width: 8, height: 8)
                Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(JcTheme.text)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(n) \(ServicesStyle.label(tone))")
        }
    }

    private var summaryLine: String {
        let errors = count(.error), warnings = count(.warning)
        if errors > 0 { return errors == 1 ? "1 needs you" : "\(errors) need you" }
        if warnings > 0 { return warnings == 1 ? "1 to keep an eye on" : "\(warnings) to keep an eye on" }
        if store.services.isEmpty { return store.pending.isEmpty ? "No services connected" : "Checking…" }
        return "All good"
    }

    private var countLine: String {
        let n = store.services.count + store.pending.count
        return "\(n) service\(n == 1 ? "" : "s") connected"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No services yet")
                .font(.system(size: 16, weight: .semibold))
            Text("Add a key for Stripe, GitHub, Vercel, n8n, Notion, Cal.com or Resend and Jarvis keeps an eye on it: payments, failing CI, deploys, workflow runs, bookings and emails.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
            NavigationLink(value: ServicesRoute.keys(.services(nil))) {
                Label("Add keys", jcIcon: "plus")
            }
            .buttonStyle(.jcGlass(compact: true))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private var connectMore: some View {
        NavigationLink(value: ServicesRoute.keys(.services(nil))) {
            HStack(spacing: 10) {
                JcIcon("plus", size: 14).foregroundStyle(JcTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect more")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(store.unconfigured.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
            }
            .padding(14)
            .contentShape(Rectangle())
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// One service on the list: its state dot, name, headline and why, the latest
/// items, and for GitHub the last half-year of contributions.
struct ServiceCard: View {
    let snapshot: ServiceSnapshot

    private var color: Color { ServicesStyle.color(snapshot.tone) }

    private var preview: [ServiceItem] {
        Array((snapshot.sections.first?.items ?? []).prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                    .shadow(color: color.opacity(0.6), radius: snapshot.tone == .error ? 4 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(snapshot.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let updated = snapshot.updatedAt {
                            Text(ServicesFormat.ago(updated))
                                .font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                        }
                        JcIcon("chevron.right", size: 11).foregroundStyle(JcTheme.muted)
                    }
                    if !snapshot.headline.isEmpty {
                        Text(snapshot.headline)
                            .font(.system(size: 14))
                            .foregroundStyle(JcTheme.text.opacity(0.88))
                            .lineLimit(2)
                    }
                    if !snapshot.reason.isEmpty {
                        Text(snapshot.reason)
                            .font(.system(size: 13))
                            .foregroundStyle(snapshot.tone == .error || snapshot.tone == .warning ? color : JcTheme.muted)
                            .lineLimit(2)
                    }
                    if let error = snapshot.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.danger)
                            .lineLimit(3)
                    }
                }
            }
            if let github = snapshot.github {
                ContributionGrid(activity: github, weeks: 26)
                    .padding(.leading, 22)
            }
            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(preview) { item in
                        HStack(spacing: 7) {
                            Circle().fill(ServicesStyle.color(item.tone)).frame(width: 5, height: 5)
                            Text(item.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(JcTheme.text.opacity(0.8))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let value = item.value {
                                Text(value)
                                    .font(.system(size: 12))
                                    .foregroundStyle(JcTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.displayName), \(ServicesStyle.label(snapshot.tone)). \(snapshot.headline). \(snapshot.reason)")
    }
}

/// A service with a key whose first poll hasn't come back yet.
private struct PendingServiceCard: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(JcTheme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text("Checking for the first time…")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.amber)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Style

enum ServicesStyle {
    static func color(_ tone: ServiceTone) -> Color {
        switch tone {
        case .ok: return JcTheme.success
        case .warning: return JcTheme.amber
        case .error: return JcTheme.danger
        case .info: return JcTheme.accent
        case .idle: return JcTheme.muted
        }
    }

    static func label(_ tone: ServiceTone) -> String {
        switch tone {
        case .ok: return "all good"
        case .warning: return "needs a look"
        case .error: return "needs you"
        case .info: return "news"
        case .idle: return "quiet"
        }
    }

    /// Up or down over 24 h.
    static func change(_ percent: Double) -> Color {
        percent >= 0 ? JcTheme.success : JcTheme.danger
    }
}

// MARK: - Visibility

extension View {
    /// Reports whether this pushed More screen is really on screen: shown in the
    /// stack (not covered by a pushed screen), the More tab selected, the app in
    /// the foreground. `onTabVisibilityChange` alone misses a return from a
    /// pushed screen: the page stays alive underneath it, so its initial-only
    /// `onChange` never fires again.
    func servicesVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ServicesVisibilityModifier(action: action))
    }
}

private struct ServicesVisibilityModifier: ViewModifier {
    let action: (Bool) -> Void
    /// Optional so a page hosted without the shell (previews, tests) still works.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

    private var foreground: Bool {
        scenePhase == .active && (router.map { $0.selectedTab == .more } ?? true)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen = true
                action(foreground)
            }
            .onDisappear {
                onScreen = false
                action(false)
            }
            .onChange(of: foreground) { _, now in
                if onScreen { action(now) }
            }
    }
}

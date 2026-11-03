import Observation
import SwiftUI

/// The integration's own page UI, at the top of its screen. Draws nothing when the
/// integration has no UI, so the generic sections below are the whole page then.
struct IntegrationUIPageSection: View {
    @Bindable var store: IntegrationUIStore

    var body: some View {
        if let root = store.root {
            VStack(alignment: .leading, spacing: 10) {
                if let error = store.error { IntegrationUIErrorLine(text: error) }
                IntegrationUIRenderer.view(root, store: store)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .integrationUIConfirm(store)
        } else if store.loading && !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }
}

/// The failure of the last load or action, above the UI it left as it was.
struct IntegrationUIErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.amber)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Asks before an action whose script declares `confirm`.
    func integrationUIConfirm(_ store: IntegrationUIStore) -> some View {
        alert(store.pendingConfirm.flatMap { store.confirms[$0.name] } ?? "",
              isPresented: Binding(get: { store.pendingConfirm != nil },
                                   set: { if !$0 { store.pendingConfirm = nil } }),
              presenting: store.pendingConfirm) { action in
            Button("Cancel", role: .cancel) { store.cancelPending() }
            Button("Continue") { Task { await store.perform(action) } }
        }
    }
}

// MARK: - Cards on the Integrations tab

/// `GET /api/integration-cards`: every integration's card, each with its own store
/// so its actions run and refresh independently.
@Observable
@MainActor
final class IntegrationUICardsStore {
    private let api: JarvisAPI
    private(set) var cards: [IntegrationUIStore] = []
    private(set) var names: [String: [String]] = [:]
    private(set) var hasLoaded = false
    /// A card's toast, shown at the foot of the tab rather than over the card.
    var toast: String?

    private static let orderKey = "integrationUI.cardOrder"
    private static let namesKey = "integrationUI.cardNames"

    init(api: JarvisAPI = .shared) {
        self.api = api
        // Last known cards, so the tab doesn't open on an empty section.
        let ids = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        cards = ids.map { IntegrationUIStore(integrationID: $0, presentation: .card, api: api) }
            .filter { $0.root != nil }
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: [String]] ?? [:]
    }

    func name(of id: String) -> String { names[id]?.first ?? id }
    func icon(of id: String) -> String { (names[id] ?? []).dropFirst().first ?? "" }

    func refresh() async {
        do {
            let rows = try await api.get("/api/integration-cards", timeout: 60).array(key: "cards")
            let entries = rows.compactMap { $0 as? [String: Any] }.map(IntegrationUICard.init(json:))
                .filter { !$0.id.isEmpty }
            let existing = Dictionary(cards.map { ($0.integrationID, $0) }, uniquingKeysWith: { a, _ in a })
            cards = entries.map { entry in
                if let store = existing[entry.id] {
                    store.update(from: entry)
                    return store
                }
                return IntegrationUIStore(card: entry, api: api)
            }
            names = Dictionary(entries.map { ($0.id, [$0.name, $0.icon]) }, uniquingKeysWith: { a, _ in a })
            UserDefaults.standard.set(entries.map(\.id), forKey: Self.orderKey)
            UserDefaults.standard.set(names, forKey: Self.namesKey)
        } catch {
            // An older server without the endpoint, or offline: keep what's cached.
        }
        hasLoaded = true
    }
}

/// One integration's card: its name (tap → the integration) over the card UI.
struct IntegrationUICardView: View {
    @Bindable var store: IntegrationUIStore
    let name: String
    let icon: String
    let integration: Integration?
    var onToast: (String) -> Void = { _ in }

    var body: some View {
        JcCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = store.error { IntegrationUIErrorLine(text: error) }
                if let root = store.root { IntegrationUIRenderer.view(root, store: store) }
            }
        }
        .integrationUIConfirm(store)
        .onChange(of: store.toast) { _, message in
            guard let message else { return }
            onToast(message)
            store.toast = nil
        }
    }

    @ViewBuilder
    private var header: some View {
        if let integration {
            NavigationLink(value: integration) { headerRow }.buttonStyle(.plain)
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            JcIconSquare(symbol: IntegrationIcon.symbol(for: icon))
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            JcRowChevron()
        }
        .contentShape(Rectangle())
    }
}

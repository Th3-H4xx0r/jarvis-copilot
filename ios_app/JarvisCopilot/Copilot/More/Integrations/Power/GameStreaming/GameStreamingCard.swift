import SwiftUI

/// The Game Streaming card body, under the Power header on the Integrations tab:
/// a live line while a stream runs (with Stop), and the one main button —
/// "Stream <last game> -> <last device>". Black and white: only the main button
/// is filled; everything else is the grey Agents-style button.
struct GameStreamingCard: View {
    @State private var store: GameStreamingStore
    @State private var busy = false
    @State private var toast: String?

    init(store: GameStreamingStore = .shared) {
        _store = State(initialValue: store)
    }

    private var primary: GamePrimary? {
        GameStreamingCardModel.primary(store.status, recent: store.lastRecent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let live = GameStreamingCardModel.liveLabel(store.status) {
                HStack(spacing: 8) {
                    StatusPill(live, color: JcTheme.text, live: true, dense: true)
                    Spacer(minLength: 0)
                    Button("Stop") { act { await store.stop() } }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(busy)
                }
            }
            if let primary {
                GradientButton(GameStreamingCardModel.primaryTitle(primary),
                               symbol: "gamecontroller", busy: busy, full: true) {
                    act { await store.start(target: primary.target, game: primary.game) }
                }
            } else if store.status != nil, (store.status?.targets.isEmpty ?? true) {
                Text("Add a target device on the page to stream.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
            }
            if let toast {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task { if store.status == nil { await store.refresh() } }
    }

    private func act(_ work: @escaping () async -> GameActionResult) {
        busy = true
        toast = nil
        Task {
            let result = await work()
            busy = false
            switch result {
            case .failed(let message): toast = message
            case .ok(let note): toast = note
            }
        }
    }
}

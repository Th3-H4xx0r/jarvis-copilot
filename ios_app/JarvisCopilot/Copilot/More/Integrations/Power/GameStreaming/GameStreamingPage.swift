import SwiftUI

/// The Game Streaming page body, shown inside the Power integration page (which
/// frames it with the on/off header, the Sunshine settings form and the
/// schedules/data link). Here: live status, a game picker, the targets with
/// "Stream" buttons, the paired devices with Unpair, a Pair sheet and the recent
/// streams. Black and white — only a page has no single main button, so every
/// control here is the grey Agents-style button.
struct GameStreamingPage: View {
    @State private var store: GameStreamingStore
    @State private var pairing = false
    @State private var banner: String?
    @State private var busy = false

    init(store: GameStreamingStore = .shared) {
        _store = State(initialValue: store)
    }

    private var status: GameStreamingStatus? { store.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner {
                IntegrationUIErrorLine(text: banner)
                    .padding(.top, 8)
            }
            liveSection
            gameSection
            targetsSection
            pairedSection
            recentSection
        }
        .task { if store.status == nil { await store.refresh() } }
        .sheet(isPresented: $pairing) {
            GameStreamingPinSheet(store: store) { banner = $0 }
        }
    }

    // MARK: live

    @ViewBuilder
    private var liveSection: some View {
        JcSectionLabel("Status", first: true)
        JcCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                    Text(statusDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 8)
                if status?.live.active == true {
                    Button("Stop") { act { await store.stop() } }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(busy)
                }
            }
        }
    }

    private var statusColor: Color {
        if status?.live.active == true { return JcTheme.text }
        return (status?.reachable ?? false) ? JcTheme.text : JcTheme.muted
    }

    private var statusTitle: String {
        if let live = GameStreamingCardModel.liveLabel(status) { return live }
        return (status?.reachable ?? false) ? "Idle" : "Host unreachable"
    }

    private var statusDetail: String {
        if let client = status?.live.client, status?.live.active == true { return "On \(client)" }
        if status?.reachable ?? false { return "Sunshine is up and ready" }
        return "Waking or offline — start still queues a stream"
    }

    // MARK: game picker

    @ViewBuilder
    private var gameSection: some View {
        let apps = status?.apps ?? []
        JcSectionLabel("Game")
        JcCard(padding: 0) {
            if apps.isEmpty {
                JcRow(symbol: "gamecontroller", title: "No games found",
                      subtitle: store.loading ? "Reading the host…" : "They appear once Sunshine lists them",
                      last: true) { EmptyView() }
            } else {
                JcRow(symbol: "gamecontroller", title: "Game", last: true) {
                    Menu {
                        ForEach(apps) { app in
                            Button { store.chosenGame = app.name } label: {
                                if app.name == store.chosenGame {
                                    Label(app.name, systemImage: "checkmark")
                                } else {
                                    Text(app.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.chosenGame.isEmpty ? (apps.first?.name ?? "Pick") : store.chosenGame)
                                .font(.system(size: 15))
                                .foregroundStyle(JcTheme.text)
                                .lineLimit(1)
                            JcIcon("chevron.up.chevron.down", size: 11).foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: targets

    @ViewBuilder
    private var targetsSection: some View {
        let targets = status?.targets ?? []
        JcSectionLabel("Stream to")
        if targets.isEmpty {
            JcCard {
                Text("No devices yet. Add them under Set up below — pick each device's type and Jarvis handles the rest.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            JcCard(padding: 0) {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    JcRow(symbol: symbol(for: target.kind), title: target.name,
                          subtitle: target.host.isEmpty ? target.kindLabel : "\(target.kindLabel) · \(target.host)",
                          last: index == targets.count - 1) {
                        Button("Stream") {
                            act { await store.start(target: target.name, game: chosenGame) }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(busy || (status?.apps.isEmpty ?? true))
                    }
                }
            }
        }
    }

    private var chosenGame: String {
        store.chosenGame.isEmpty ? (status?.apps.first?.name ?? "") : store.chosenGame
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "mac": return "laptopcomputer"
        case "androidtv", "android": return "tv"
        case "ios": return "iphone"
        default: return "display"
        }
    }

    // MARK: paired

    @ViewBuilder
    private var pairedSection: some View {
        let paired = status?.paired ?? []
        JcSectionLabel("Paired devices")
        JcCard(padding: 0) {
            ForEach(Array(paired.enumerated()), id: \.element.id) { index, device in
                JcRow(symbol: "dot.radiowaves.left.and.right", title: device.name,
                      subtitle: device.uuid.isEmpty ? nil : String(device.uuid.prefix(8)),
                      last: false) {
                    Button("Unpair") { act { await store.unpair(device) } }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                        .disabled(busy)
                }
            }
            JcRow(symbol: "plus", title: "Pair a device",
                  subtitle: "Enter the PIN Moonlight shows", last: true,
                  action: { pairing = true })
        }
    }

    // MARK: recent

    @ViewBuilder
    private var recentSection: some View {
        if !store.recents.isEmpty {
            JcSectionLabel("Recent streams")
            JcCard(padding: 0) {
                ForEach(Array(store.recents.enumerated()), id: \.element.id) { index, recent in
                    JcRow(symbol: "clock.arrow.circlepath",
                          title: "\(recent.game) -> \(recent.target)",
                          subtitle: recent.at.formatted(.relative(presentation: .named)),
                          last: index == store.recents.count - 1) {
                        Button("Again") {
                            act { await store.start(target: recent.target, game: recent.game) }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(busy)
                    }
                }
            }
        }
    }

    private func act(_ work: @escaping () async -> GameActionResult) {
        busy = true
        banner = nil
        Task {
            let result = await work()
            busy = false
            switch result {
            case .failed(let message): banner = message
            case .ok(let note): banner = note
            }
        }
    }
}

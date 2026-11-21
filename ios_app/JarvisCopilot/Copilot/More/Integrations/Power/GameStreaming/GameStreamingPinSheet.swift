import Observation
import SwiftUI

/// Backs the pair sheet: polls the devices waiting to pair every 2 s while the sheet is
/// open, picks the only one automatically, prefills its name (editable), and answers
/// it with the PIN it shows. Sunshine pairs a specific waiting request, so the PIN is
/// sent with that request's id.
@MainActor
@Observable
final class GamePairStore {
    private(set) var reply: GamePairingsReply?
    private(set) var selectedID: String?
    private(set) var busy = false
    private(set) var error: String?
    var pin = ""
    /// The name the device gets in Sunshine. Prefilled from the waiting request until the
    /// user types their own.
    var device = "" { didSet { if device != prefilled { deviceEdited = true } } }

    @ObservationIgnored private let store: GameStreamingStore
    @ObservationIgnored private var deviceEdited = false
    @ObservationIgnored private var prefilled = ""

    init(store: GameStreamingStore) { self.store = store }

    var pairings: [GamePairing] { reply?.pairings ?? [] }
    var selected: GamePairing? { pairings.first { $0.id == selectedID } }
    var waitingLine: String { GamePairModel.waitingLine(reply) }

    var canPair: Bool {
        selected != nil && !busy &&
        !device.trimmingCharacters(in: .whitespaces).isEmpty &&
        pin.trimmingCharacters(in: .whitespaces).count >= 4
    }

    /// Load the waiting devices once.
    func load() async {
        apply(await store.pairings())
    }

    /// Load now, then every `interval` seconds while the sheet's task lives.
    func poll(every interval: Double = 2) async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    func apply(_ reply: GamePairingsReply) {
        self.reply = reply
        let next = GamePairModel.selection(current: selectedID, in: reply.pairings)
        if next != selectedID { select(next) }
    }

    func select(_ id: String?) {
        selectedID = id
        guard !deviceEdited, let pick = pairings.first(where: { $0.id == id }) else { return }
        prefilled = pick.label
        device = pick.label
    }

    /// Answer the picked request with the PIN. On success the device list refreshes
    /// (the store re-reads status); on failure `error` holds the server's words.
    func submit() async -> GamePairOutcome? {
        guard canPair, let id = selectedID else { return nil }
        busy = true
        error = nil
        defer { busy = false }
        let outcome = await store.pair(device: device.trimmingCharacters(in: .whitespaces),
                                       pin: pin.trimmingCharacters(in: .whitespaces),
                                       pairingID: id)
        switch outcome {
        case .paired: break
        case .offline(let message), .failed(let message): error = message
        }
        return outcome
    }
}

/// Pair a Moonlight device: on the device, open Moonlight and tap the PC; it shows a PIN
/// and appears here as waiting. Pick it (the only one is picked for you), check its name
/// and enter the PIN. The one commit is the main (filled) button; the rest stays quiet.
struct GameStreamingPinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pair: GamePairStore
    var onResult: (String) -> Void

    init(store: GameStreamingStore, onResult: @escaping (String) -> Void) {
        _pair = State(initialValue: GamePairStore(store: store))
        self.onResult = onResult
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    waitingSection
                    if pair.selected != nil { detailsSection }
                    if let error = pair.error {
                        IntegrationUIErrorLine(text: error).padding(.top, 12)
                    }
                    GradientButton("Pair", busy: pair.busy, full: true,
                                   action: pair.canPair ? submit : nil)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .jcPageChrome("Pair a device") {
                JcPageButton("xmark", label: "Close") { dismiss() }
            }
            .task { await pair.poll() }
        }
    }

    // MARK: waiting devices

    @ViewBuilder
    private var waitingSection: some View {
        JcSectionLabel("Waiting to pair", first: true)
        if pair.pairings.isEmpty {
            JcCard {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    JcLoader(size: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        .accessibilityHidden(true)
                    Text(pair.waitingLine)
                        .font(.system(size: 14))
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        } else {
            JcCard(padding: 0) {
                ForEach(Array(pair.pairings.enumerated()), id: \.element.id) { index, device in
                    JcRow(symbol: "display", title: device.label,
                          subtitle: device.address.isEmpty ? nil : device.address,
                          last: index == pair.pairings.count - 1,
                          action: { pair.select(device.id) }) {
                        if device.id == pair.selectedID {
                            JcIcon("checkmark", size: 13, weight: .semibold)
                                .foregroundStyle(JcTheme.text)
                        }
                    }
                    .accessibilityAddTraits(device.id == pair.selectedID ? .isSelected : [])
                }
            }
            Text(pair.waitingLine)
                .font(.system(size: 12.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    // MARK: name + PIN

    @ViewBuilder
    private var detailsSection: some View {
        JcSectionLabel("Device")
        JcCard {
            VStack(alignment: .leading, spacing: 12) {
                field("Name", text: Binding(get: { pair.device }, set: { pair.device = $0 }),
                      placeholder: "Living Room TV", keyboard: .default, caps: .words)
                Divider().overlay(JcTheme.border)
                field("PIN", text: Binding(get: { pair.pin }, set: { pair.pin = $0 }),
                      placeholder: "1234", keyboard: .numberPad, caps: .never)
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType,
                       caps: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            TextField(placeholder, text: text)
                .font(.system(size: 16))
                .foregroundStyle(JcTheme.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(caps)
                .autocorrectionDisabled()
        }
    }

    private func submit() {
        Task {
            guard let outcome = await pair.submit() else { return }
            if case .paired(let detail) = outcome {
                onResult(detail ?? "Paired \(pair.device)")
                dismiss()
            }
        }
    }
}

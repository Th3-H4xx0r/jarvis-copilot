import SwiftUI

/// A host's Controls: its own and its linked wearables', as tiles — or a quiet note while there
/// are none.
struct WearableControlsSection: View {
    let controls: [WearableControl]
    let perform: (String, WearableControlValue) async throws -> Void

    var body: some View {
        CardGroup("Controls") {
            if controls.isEmpty {
                CardEmptyBlock(symbol: "slider.horizontal.3", text: "No controls yet — linked devices add theirs here.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top),
                                    GridItem(.flexible(), spacing: 10, alignment: .top)],
                          spacing: 10) {
                    ForEach(controls) { WearableControlTile(control: $0, perform: perform) }
                }
                .padding(12)
            }
        }
    }
}

/// One control: a toggle flips on tap, a button runs on tap, a level has a slider, a choice a menu.
/// A failure shows under the tile and nowhere else.
struct WearableControlTile: View {
    let control: WearableControl
    let perform: (String, WearableControlValue) async throws -> Void

    @State private var busy = false
    @State private var error: String?
    @State private var draft: Double?

    private var isOn: Bool { if case .toggle(true) = control.kind { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                JcIcon(control.symbol, size: 18).foregroundStyle(isOn ? Color.white : JcTheme.accent)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Text(control.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            detail
            if let error {
                Text(error).font(.caption2).foregroundStyle(JcTheme.danger).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: isOn ? JcTheme.accent.opacity(0.55) : .clear)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            switch control.kind {
            case .toggle(let on): run(.toggle(!on))
            case .button: run(.press)
            case .level, .choice: break
            }
        }
        .opacity(control.enabled ? 1 : 0.45)
        .disabled(!control.enabled || busy)
        .accessibilityElement(children: .combine)
        .accessibilityValue(control.valueText ?? "")
    }

    @ViewBuilder private var detail: some View {
        switch control.kind {
        case .toggle(let on):
            Text(on ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
        case .button:
            Text("Tap to run").font(.caption).foregroundStyle(.secondary)
        case .level(let value, let range, let step, let unit):
            VStack(alignment: .leading, spacing: 2) {
                Text(WearableControl.format(draft ?? value) + (unit.map { " \($0)" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range, step: step > 0 ? step : 1) { editing in
                    if !editing, let draft { run(.level(draft)) }
                }
                .tint(JcTheme.accent)
            }
        case .choice(let selected, let options):
            Menu {
                ForEach(options, id: \.id) { option in
                    Button(option.title) { run(.choice(option.id)) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first { $0.id == selected }?.title ?? selected).lineLimit(1)
                    JcIcon("chevron.up.chevron.down", size: 11)
                }
                .font(.caption)
                .foregroundStyle(JcTheme.accent)
            }
        }
    }

    private func run(_ value: WearableControlValue) {
        busy = true
        error = nil
        Task {
            do { try await perform(control.id, value) } catch { self.error = error.localizedDescription }
            busy = false
            draft = nil
        }
    }
}

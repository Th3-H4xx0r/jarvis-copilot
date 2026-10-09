import SwiftUI

/// Climate for remote start, like Toyota's: custom climate, temperature, defrost — drafts until Save.
struct CarClimateSheet: View {
    @ObservedObject var store: ToyotaStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ToyotaCar.Climate?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let climate = draft ?? store.car?.climate {
                        form(climate)
                    } else {
                        ContentUnavailableView("Climate isn't available", systemImage: "fan",
                                               description: Text("Your car doesn't report remote-start climate settings."))
                    }
                }
                .padding(.vertical, 16)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Climate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationBackground(JcTheme.bg)
    }

    @ViewBuilder private func form(_ c: ToyotaCar.Climate) -> some View {
        // Only what the car reports: a missing setting would be refused if it were sent.
        if c.custom != nil {
            CardGroup(footer: "Uses the settings below when you remote start your car.") {
                Row { Toggle("Custom climate", isOn: binding(c, \.custom)).tint(JcTheme.accent) }
            }
        }
        if c.temp != nil {
            temperature(c)
        }
        if c.defrostFront != nil || c.defrostRear != nil {
            CardGroup("Defrost") {
                if c.defrostFront != nil {
                    Row { Toggle("Front", isOn: binding(c, \.defrostFront)).tint(JcTheme.accent) }
                }
                if c.defrostFront != nil && c.defrostRear != nil { Divider().padding(.leading, 16) }
                if c.defrostRear != nil {
                    Row { Toggle("Rear", isOn: binding(c, \.defrostRear)).tint(JcTheme.accent) }
                }
            }
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(JcTheme.danger).padding(.horizontal, 20)
        }
        Button {
            save()
        } label: {
            if saving { ProgressView() } else { Text("Save Settings").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.jcGlass(full: true))
        .disabled(saving || draft == nil)
        .padding(.horizontal, 16)
    }

    private func temperature(_ c: ToyotaCar.Climate) -> some View {
        VStack(spacing: 12) {
            Text(c.temp.map { "\(WearableControl.format($0))\(c.unit)" } ?? "—")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 14) {
                JcIcon("fan", size: 18).foregroundStyle(.secondary)
                Slider(value: Binding(get: { c.temp ?? c.min },
                                      set: { value in update(c) { $0.temp = WearableControl.snap(value, range: c.min...max(c.max, c.min), step: c.step) } }),
                       in: c.min...max(c.max, c.min + 1))
                    .tint(JcTheme.accent)
                JcIcon("heat.waves", size: 18).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
        }
    }

    private func binding(_ c: ToyotaCar.Climate, _ key: WritableKeyPath<ToyotaCar.Climate, Bool?>) -> Binding<Bool> {
        Binding(get: { c[keyPath: key] ?? false },
                set: { value in update(c) { $0[keyPath: key] = value } })
    }

    /// Changes the draft, starting from the car's saved climate.
    private func update(_ base: ToyotaCar.Climate, _ change: (inout ToyotaCar.Climate) -> Void) {
        var next = draft ?? base
        change(&next)
        draft = next
        error = nil
    }

    private func save() {
        guard let draft else { return }
        saving = true
        Task {
            do {
                try await store.saveClimate(draft)
                dismiss()
            } catch {
                self.error = apiErrorMessage(error)
            }
            saving = false
        }
    }
}

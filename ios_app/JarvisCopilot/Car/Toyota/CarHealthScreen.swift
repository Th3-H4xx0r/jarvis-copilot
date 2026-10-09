import SwiftUI

/// Health: whatever the car reports — tyre warnings, next service, oil, key-fob battery.
struct CarHealthScreen: View {
    let car: ToyotaCar?

    var body: some View {
        ScrollView {
            CardGroup(footer: "From the car's last report to Toyota.") {
                let items = car?.health ?? []
                if items.isEmpty {
                    Row { Text("Nothing reported yet.").foregroundStyle(.secondary) }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 60) }
                    ToyotaStatusRow(icon: icon(for: item), title: item.title, value: item.detail, ok: item.ok)
                }
            }
            .padding(.vertical, 16)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func icon(for item: ToyotaCar.HealthItem) -> String {
        let id = (item.id + " " + item.title).lowercased()
        if id.contains("tire") || id.contains("tyre") { return "tirepressure" }
        if id.contains("oil") { return "oilcan.fill" }
        if id.contains("fob") { return "key.fill" }
        if id.contains("service") { return "wrench.and.screwdriver.fill" }
        return "heart.text.square.fill"
    }
}

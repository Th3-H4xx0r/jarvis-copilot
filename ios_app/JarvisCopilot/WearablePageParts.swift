import SwiftUI

/// A wearable's card on Devices: its model turning on the right; name, model, link and battery on
/// the left. The R12, X5 and band cards are this with their own picture.
struct WearableCard<Picture: View>: View {
    let name: String
    let model: String
    /// 0 when the device was put in the list from iOS's own link, not heard in a scan.
    let rssi: Int
    let battery: RingBattery?
    let connected: Bool
    /// When the device was last in range, for the offline corner note.
    var lastSeen: Date? = nil
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                picture()
                    .environment(\.sceneStills, true)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(JcText.title)
                    .lineLimit(1)
                Text(model)
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: JcTheme.success)
                    } else if rssi == 0 {
                        // Remembered from iOS's own link, not answering: not a signal reading.
                        DisconnectedPill()
                    } else {
                        MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                                   value: "\(rssi) dBm", tint: JcMetric.activity)
                    }
                    if let battery {
                        MetricPill(icon: battery.charging ? "bolt.fill" : "battery.75", label: "Battery",
                                   value: "\(battery.percent)%",
                                   tint: batteryTint(battery.percent) ?? JcTheme.success)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !connected && rssi == 0)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous).strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

/// A row on a wearable's page that opens something: icon, what it opens, a line under it, chevron.
struct DeviceLinkLabel: View {
    let icon: String
    var tint: Color = JcTheme.accent
    let title: String
    let subtitle: String

    var body: some View {
        Row(minHeight: 56) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 8)
                JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
    }
}

/// `DeviceLinkLabel` as a button in its own card.
struct DeviceLink: View {
    let icon: String
    var tint: Color = JcTheme.accent
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        CardGroup {
            Button(action: action) {
                DeviceLinkLabel(icon: icon, tint: tint, title: title, subtitle: subtitle)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The settings row at the foot of a wearable's page.
struct DeviceSettingsLink: View {
    var title = "Settings & diagnostics"
    let action: () -> Void

    var body: some View {
        CardGroup {
            Button(action: action) {
                Row {
                    HStack {
                        Text(title)
                        Spacer()
                        JcIcon("chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(JcTheme.muted.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// What the device is reporting right now, one labelled row each; nothing when it says nothing.
struct DeviceLiveRows: View {
    var title = "Live from the ring"
    let rows: [(String, String)]

    var body: some View {
        if !rows.isEmpty {
            CardGroup(title) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    Row { LabeledContent(row.0, value: row.1) }
                }
            }
        }
    }
}

/// Why the last action on the page failed, under the status line.
struct DeviceActionError: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(JcTheme.amber)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// The workout picker every workout-capable wearable's page opens; the workout runs on
    /// the shared controller, tracked by `wearable`.
    func workoutPicker(isPresented: Binding<Bool>, wearable: String) -> some View {
        sheet(isPresented: isPresented) {
            let workout = WearablesHub.shared.ring.workout
            WorkoutPicker(wearable: wearable,
                          onTemplate: { workout.startStrength(template: $0) }) { sport in workout.start(sport) }
        }
    }
}

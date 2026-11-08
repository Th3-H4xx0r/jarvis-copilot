import SwiftUI

/// A device's card on Devices: its picture at the right, name and subtitle top left, status pills
/// bottom left, on the app's glass card. Every Devices card is this with its own picture and pills.
struct DeviceCard<Picture: View, Pills: View>: View {
    let name: String
    let subtitle: String
    /// A long name (a board's) may take two lines, shrinking to fit beside the picture.
    var nameLines = 1
    /// Pins the picture to the top instead of centring it.
    var pictureAtTop = false
    var lastSeen: Date? = nil
    /// Whether the "last seen" note shows in the corner.
    var showsLastSeen = false
    var border: Color = JcTheme.border
    /// Sized and placed by the card that owns it.
    @ViewBuilder let picture: () -> Picture
    @ViewBuilder let pills: () -> Pills

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top) {
                Spacer()
                picture()
            }
            .frame(maxHeight: .infinity, alignment: pictureAtTop ? .top : .center)
            VStack(alignment: .leading, spacing: 0) {
                if nameLines > 1 {
                    Text(name)
                        .font(JcText.title)
                        .lineLimit(nameLines)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 190, alignment: .leading)
                } else {
                    Text(name)
                        .font(JcText.title)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) { pills() }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: showsLastSeen)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

/// A wearable's card: its model turning at the right, and its link and battery.
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
        DeviceCard(name: name, subtitle: model, lastSeen: lastSeen, showsLastSeen: !connected && rssi == 0) {
            picture()
                .environment(\.sceneStills, true)
                .frame(width: 124, height: 124)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        } pills: {
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

import SwiftUI

/// The door alarm's card on the Devices tab, under the car: the hub in 3D, the alarm state, each
/// door and the link to the hub. Opens the Door Alarm page.
struct DoorAlarmEntryCard: View {
    var namespace: Namespace.ID
    @ObservedObject private var store: DoorAlarmStore = .shared

    var body: some View {
        NavigationLink {
            DoorAlarmPage().zoomTransition(id: DoorAlarmDevice.kind, in: namespace)
        } label: {
            DoorAlarmCard(name: DoorAlarmDevice.shared.name, state: store.state)
        }
        .buttonStyle(.plain)
        .zoomSource(id: DoorAlarmDevice.kind, in: namespace)
        .task { if store.state == nil { await store.load() } }
    }
}

struct DoorAlarmCard: View {
    let name: String
    let state: DoorState?

    private var alarm: DoorAlarmInfo? { state?.alarm }

    private var stateTint: Color {
        guard let alarm else { return JcTheme.muted }
        if alarm.isAlerting { return JcTheme.danger }
        return alarm.isArmed ? JcTheme.accent : JcTheme.muted
    }

    private var subtitle: String {
        guard let state else { return "Smart Life door sensors" }
        if !state.setup.hub { return "Not set up yet" }
        let n = state.contacts.count
        return "\(n) door\(n == 1 ? "" : "s") · " + (state.links.localAlive ? "local" : state.links.cloudAlive ? "cloud" : "offline")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top) {
                Spacer()
                DoorHubView(state: DoorHubView.Look(alarm))
                    .environment(\.sceneStills, true)
                    .frame(width: 210, height: 150)
                    .padding(.trailing, -10)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(JcText.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    MetricPill(icon: alarm?.isArmed == true ? "lock.shield.fill" : "lock.open",
                               label: "Alarm", value: alarm?.title ?? "—", tint: stateTint)
                    if let open = state?.openContacts.first {
                        MetricPill(icon: "door.left.hand.open", label: "Open", value: open.name, tint: JcTheme.amber)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
            .strokeBorder(alarm?.isAlerting == true ? JcTheme.danger.opacity(0.7) : JcTheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(alarm?.title ?? "not loaded")")
    }
}

import SwiftUI

/// The car's card on the Devices tab: always there, where the dashcam card used to be.
struct CarEntryCard: View {
    var namespace: Namespace.ID
    @ObservedObject private var presence: CarPresence = .shared
    @ObservedObject private var links: WearableLinks = .shared
    @ObservedObject private var sync: DashcamSync = .shared

    var body: some View {
        let dashcamLinked = links.host(of: DashcamDevice.identityKey) == CarDevice.kind
        NavigationLink {
            CarPage().zoomTransition(id: CarDevice.kind, in: namespace)
        } label: {
            CarCard(name: CarDevice.shared.name, subtitle: CarProfile.camry.description, inCar: presence.inCar,
                    lastSeen: presence.lastSeen, pendingUploads: dashcamLinked ? sync.pendingUploads : 0)
        }
        .buttonStyle(.plain)
        .zoomSource(id: CarDevice.kind, in: namespace)
    }
}

struct CarCard: View {
    let name: String
    let subtitle: String
    let inCar: Bool
    let lastSeen: Date?
    var pendingUploads = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top) {
                Spacer()
                if CarModel.hasBundledModel {
                    // High and to the right: the status pills keep the bottom left.
                    CarSceneView(presentation: .card, lit: inCar)
                        .environment(\.sceneStills, true)
                        .frame(width: 262, height: 150)
                        .padding(.trailing, -22)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                } else {
                    JcIcon("car", size: 34, weight: .light).foregroundStyle(JcTheme.muted).padding(.trailing, 34)
                }
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
                    if inCar {
                        MetricPill(icon: "car", label: "Status", value: "In the car", tint: JcTheme.success)
                    } else {
                        MetricPill(icon: "car", label: "Status", value: "Away", tint: JcTheme.muted)
                    }
                    if pendingUploads > 0 {
                        MetricPill(icon: "arrow.up.circle", label: "Uploads", value: "\(pendingUploads)", tint: JcTheme.amber)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !inCar)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous).strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

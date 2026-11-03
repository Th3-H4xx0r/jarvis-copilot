import SwiftUI

/// The dashcam's card on the Devices tab: always there — "Add your dashcam" until it's set up.
struct DashcamEntryCard: View {
    @ObservedObject var sync: DashcamSync = .shared
    @ObservedObject var wifi: DashcamWiFi = .shared
    var namespace: Namespace.ID

    var body: some View {
        NavigationLink {
            Group {
                if DashcamSetupStore.load() == nil { DashcamSetupView() } else { DashcamPage() }
            }
            .zoomTransition(id: DashcamDevice.identityKey, in: namespace)
        } label: {
            DashcamCard(setup: DashcamSetupStore.load(), onCamera: wifi.onCamera, phase: sync.phase,
                        lastSync: sync.lastSync, pendingUploads: sync.pendingUploads)
        }
        .buttonStyle(.plain)
        .zoomSource(id: DashcamDevice.identityKey, in: namespace)
    }
}

struct DashcamCard: View {
    let setup: DashcamSetup?
    let onCamera: Bool
    let phase: DashcamSync.Phase
    let lastSync: Date?
    let pendingUploads: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                // Turning costs a continuous render: only once a camera is set up.
                DashcamSceneView(spin: setup != nil, lit: onCamera)
                    .frame(width: 184, height: 136)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(setup?.displayName ?? "Dashcam")
                    .font(JcText.title)
                    .lineLimit(1)
                Text(setup == nil ? "Add your dashcam" : "Dashcam · \(setup?.ssid ?? "")")
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if setup == nil {
                        MetricPill(icon: "plus.circle", label: "Status", value: "Not set up", tint: JcTheme.muted)
                    } else if onCamera {
                        MetricPill(icon: "wifi", label: "Status", value: phase.label, tint: JcTheme.success)
                    } else {
                        MetricPill(icon: "wifi.slash", label: "Status", value: "Away", tint: JcTheme.muted)
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
        .lastSeenCorner(lastSync, visible: setup != nil && !onCamera)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous).strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

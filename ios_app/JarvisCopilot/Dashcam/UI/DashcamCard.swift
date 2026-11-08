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
        DeviceCard(name: setup?.displayName ?? "Dashcam",
                   subtitle: setup == nil ? "Add your dashcam" : "Dashcam · \(setup?.ssid ?? "")",
                   lastSeen: lastSync, showsLastSeen: setup != nil && !onCamera) {
            // Turning costs a continuous render: only once a camera is set up.
            DashcamSceneView(spin: setup != nil, lit: onCamera)
                .frame(width: 184, height: 136)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
        } pills: {
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
}

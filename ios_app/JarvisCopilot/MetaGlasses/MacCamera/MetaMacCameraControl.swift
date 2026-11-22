import SwiftUI

/// "Send to Mac camera" in the live viewer: his switch for the Mac's Jarvis Glasses camera
/// (FaceTime, Zoom, Meet on the Mac), and what it's doing right now.
struct MetaMacCameraControl: View {
    @ObservedObject var camera = GlassesMacCamera.shared

    var body: some View {
        VStack(spacing: 6) {
            Button { camera.enabled.toggle() } label: {
                Label(camera.enabled ? "Sending to Mac camera" : "Send to Mac camera",
                      systemImage: camera.phase == .sending ? "video.fill" : "macbook")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.jcGlass)
            .accessibilityValue(camera.enabled ? "On" : "Off")
            if camera.enabled {
                Text(camera.phase.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
        }
    }
}

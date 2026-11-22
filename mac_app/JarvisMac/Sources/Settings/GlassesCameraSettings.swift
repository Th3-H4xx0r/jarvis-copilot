import SwiftUI

/// Settings → Glasses camera: install the "Jarvis Glasses" camera and see what it's doing.
struct GlassesCameraSettings: View {
    @State private var installer = GlassesCameraInstaller.shared
    @State private var service = GlassesCameraService.shared

    var body: some View {
        Form {
            Section {
                Text("Your Meta glasses' live video as a Mac camera. Pick “Jarvis Glasses” as the camera in FaceTime, Zoom or Meet; your iPhone sends the video, over Wi-Fi or cellular.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Camera") { Text(installText).multilineTextAlignment(.trailing) }
                LabeledContent("Right now") { Text(service.phase.text).multilineTextAlignment(.trailing) }
                HStack {
                    Button(installer.state == .installed ? "Reinstall" : "Install camera") { installer.install() }
                        .disabled(installer.state == .working)
                    if installer.state == .needsApproval {
                        Button("Open System Settings") { GlassesCameraInstaller.openApprovalSettings() }
                    }
                    Spacer()
                    if installer.state == .installed {
                        Button("Remove") { installer.uninstall() }
                    }
                }
            } header: {
                Text("Jarvis Glasses camera")
            }
            Section("On your iPhone") {
                Text("Meta glasses → Watch live → Send to Mac camera. Video only flows while your glasses are live and an app on this Mac is using the camera; otherwise the camera shows “Glasses not streaming”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            installer.check()
            service.refresh()
        }
    }

    private var installText: String {
        switch installer.state {
        case .unknown: return "Checking…"
        case .notInstalled: return service.phase == .notInstalled ? "Not installed" : "Installed"
        case .working: return "Working…"
        case .needsApproval: return "Waiting for your OK in System Settings → General → Login Items & Extensions → Camera Extensions"
        case .installed: return "Installed"
        case .restartNeeded: return "Restart your Mac to finish"
        case .failed(let why): return why
        }
    }
}

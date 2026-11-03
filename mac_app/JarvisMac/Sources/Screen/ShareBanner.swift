import AppKit
import SwiftUI

/// "Your screen is shared with Jarvis · Stop" — always on top, on every Space,
/// while any viewer is connected. Also says when Screen Recording is off.
@MainActor
enum ShareBanner {
    private static var panel: NSPanel?
    static let size = CGSize(width: 400, height: 40)

    static func update() {
        let service = ScreenShareService.shared
        let show = service.viewers > 0 || service.permissionProblem != nil
        if !show {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? make()
        panel = p
        place(p)
        p.orderFrontRegardless()
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: ShareBannerView())
        return p
    }

    private static func place(_ p: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 10,
                          width: size.width, height: size.height), display: true)
    }
}

private struct ShareBannerView: View {
    @State private var service = ScreenShareService.shared

    var body: some View {
        HStack(spacing: 10) {
            if let problem = service.permissionProblem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(problem).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button("Open Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.borderless).foregroundStyle(JcAccent.color)
                Button { service.dismissProblem() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(service.viewers > 1 ? "Your screen is shared with Jarvis · \(service.viewers) watching"
                                         : "Your screen is shared with Jarvis")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 4)
                Button("Stop") { service.stopAll() }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: ShareBanner.size.width, height: ShareBanner.size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

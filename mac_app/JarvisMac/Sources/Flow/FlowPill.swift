import AppKit
import Observation
import SwiftUI

/// A message the pill shows for a few seconds ("Allow Accessibility so Jarvis can paste").
struct FlowAnnouncement: Equatable {
    var symbol: String
    var text: String
    var action: String?
}

@MainActor
@Observable
final class FlowPillModel {
    enum Phase: Equatable { case idle, listening, locked, thinking, failed, pastedAgain }

    var phase: Phase = .idle
    var announcement: FlowAnnouncement?
    var keyLabel = FlowKey.rightOption.label
    @ObservationIgnored var onAction: (() -> Void)?
}

/// The pill at the bottom of the screen while Flow listens: nine dots that move
/// with your voice (low on the left, high on the right), a lock while hands-free,
/// a shimmer while the words are written. It never takes focus, so the app you
/// dictate into keeps the cursor; it takes clicks only while a message offers an
/// action.
@MainActor
final class FlowPillController {
    let model = FlowPillModel()
    private let bands: FlowAudioBands
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var announceWork: DispatchWorkItem?

    static let size = NSSize(width: 360, height: 64)

    init(bands: FlowAudioBands) {
        self.bands = bands
    }

    func listen() {
        announceWork?.cancel()
        model.announcement = nil
        model.phase = .listening
        sync()
    }

    func setPhase(_ phase: FlowPillModel.Phase) {
        model.phase = phase
        sync()
    }

    /// A short state ("failed", "pasted again") that goes away on its own.
    func flash(_ phase: FlowPillModel.Phase) {
        model.phase = phase
        sync()
        rest(after: 1.2)
    }

    func rest(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.phase = .idle
            self.sync()
        }
        hideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func announce(_ a: FlowAnnouncement, for seconds: TimeInterval = 8, action: (() -> Void)? = nil) {
        model.announcement = a
        model.onAction = action
        sync()
        announceWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.announcement = nil
            self.model.onAction = nil
            self.sync()
        }
        announceWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func sync() {
        let visible = model.phase != .idle || model.announcement != nil
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.ignoresMouseEvents = model.announcement?.action == nil
        position(p)
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let view = FlowPillView(model: model, bands: bands) { [weak self] in
            self?.model.onAction?()
            self?.announceWork?.perform()
        }
        p.contentView = NSHostingView(rootView: view)
        return p
    }

    /// Centred along the bottom of the screen the pointer is on.
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 28))
    }
}

private struct FlowPillView: View {
    let model: FlowPillModel
    let bands: FlowAudioBands
    let onAction: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let a = model.announcement {
                announcement(a)
            } else if model.phase != .idle {
                pill
            }
        }
        .frame(width: FlowPillController.size.width, height: FlowPillController.size.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.announcement)
    }

    private var pill: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .failed:
                Image(systemName: "mic.slash.fill").foregroundStyle(.red)
            case .pastedAgain:
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(JcAccent.color)
                Text("Pasted again").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            default:
                if model.phase == .locked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(JcAccent.color)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Dots(levels: bands.levels, thinking: model.phase == .thinking,
                         time: context.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: 70, height: 18)
                if model.phase == .locked {
                    Text("tap \(model.keyLabel) to finish").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase == .thinking ? "Writing" : "Jarvis is listening")
    }

    private func announcement(_ a: FlowAnnouncement) -> some View {
        HStack(spacing: 8) {
            Image(systemName: a.symbol).foregroundStyle(JcAccent.color)
            Text(a.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(2)
            if let action = a.action {
                Button(action, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(JcAccent.color.opacity(0.25)))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

/// The nine dots: their height follows each band's level; while thinking, a wave runs through them.
private struct Dots: View {
    let levels: [Float]
    let thinking: Bool
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<FlowBands.count, id: \.self) { i in
                Capsule()
                    .fill(JcAccent.color.opacity(thinking ? 0.55 : 0.95))
                    .frame(width: 4, height: height(i))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func height(_ i: Int) -> CGFloat {
        if thinking {
            let wave = (sin(time * 6 - Double(i) * 0.7) + 1) / 2
            return 4 + CGFloat(wave) * 8
        }
        let level = i < levels.count ? CGFloat(levels[i]) : 0
        return 4 + level * 14
    }
}

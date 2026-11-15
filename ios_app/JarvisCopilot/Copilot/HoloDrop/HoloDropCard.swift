import SwiftUI
import UIKit

/// The arrival cards' own window, above everything (sheets too). Touches outside a card fall
/// through to the app: the window only answers for what it draws.
@MainActor
final class HoloCardsWindow {
    private var window: PassThroughWindow?

    func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let w = PassThroughWindow(windowScene: scene)
        let host = UIHostingController(rootView: HoloArrivalCardsView(receiver: .shared) { [weak w] frames in
            w?.interactive = frames
        })
        host.view.backgroundColor = .clear
        w.windowLevel = .alert + 2
        w.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// A window that only exists where its cards are: touches anywhere else go to the app below.
/// (Testing the hit view doesn't work for SwiftUI — its hosting view answers for everything,
/// which sent taps on the card's own buttons through to the app.)
final class PassThroughWindow: UIWindow {
    /// The cards' frames, in window coordinates (reported by the SwiftUI view).
    var interactive: [CGRect] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        interactive.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
    }
}

struct HoloCardFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// The stack of arrivals at the top of the screen. Swipe one up to dismiss it.
struct HoloArrivalCardsView: View {
    @ObservedObject var receiver: HoloDropReceiver
    var onFrames: ([CGRect]) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(receiver.cards) { card in
                HoloArrivalCardView(card: card, receiver: receiver)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: HoloCardFrames.self, value: [g.frame(in: .global)])
                    })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .animation(.spring(duration: 0.35), value: receiver.cards)
        .onPreferenceChange(HoloCardFrames.self) { onFrames($0) }
    }
}

struct HoloArrivalCardView: View {
    let card: HoloArrivalCard
    let receiver: HoloDropReceiver
    @State private var drag: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.record.caption)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(card.expanded ? nil : 1)
                    Text("From \(card.record.sender) · \(status)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if case .working = card.state { ProgressView().tint(.white).controlSize(.small) }
            }
            if card.expanded, card.record.kind == "text" {
                ScrollView {
                    Text(card.record.text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
            if case .done = card.state {
                HStack(spacing: 6) {
                    chip("Open", .open, main: card.record.action == .open || card.record.action == .saveOpen)
                    chip("Save", .save, main: card.record.action == .save)
                    chip("Copy", .copy, main: card.record.action == .copy || card.record.action == .saveCopy)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.08).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        // Swipe it away like a notification: up, or off either side. It stays in the Holo Drop
        // page's inbox.
        .offset(x: drag.width, y: min(0, drag.height))
        .opacity(1 - min(0.6, abs(drag.width) / 400))
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation }
            .onEnded { g in
                let t = g.predictedEndTranslation
                if g.translation.height < -30 || t.height < -120 {
                    withAnimation(.easeIn(duration: 0.2)) { drag = CGSize(width: 0, height: -260) }
                    receiver.dismiss(card.id)
                } else if abs(g.translation.width) > 90 || abs(t.width) > 240 {
                    withAnimation(.easeIn(duration: 0.2)) { drag = CGSize(width: g.translation.width > 0 ? 500 : -500, height: 0) }
                    receiver.dismiss(card.id)
                } else {
                    withAnimation(.spring) { drag = .zero }
                }
            })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Holo Drop from \(card.record.sender): \(card.record.caption), \(status)")
    }

    private var status: String {
        switch card.state {
        case .working: return "arriving…"
        case .done(let words): return words
        case .failed(let why): return why
        }
    }

    private var thumb: some View {
        Group {
            if card.record.kind == "image", let url = card.fileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: card.record.symbol).font(.system(size: 18)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(width: 44, height: 44)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Grey chips; white fill only for the one the drop already did (his black & white rule).
    /// Tapped: this one spins (the Jarvis loader), the others grey out until it's done.
    private func chip(_ title: String, _ action: HoloAction, main: Bool) -> some View {
        let working = card.busy == action
        let locked = card.busy != nil && !working
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            receiver.again(card.id, action)
        } label: {
            ZStack {
                Text(title).font(.system(size: 12, weight: .medium)).opacity(working ? 0 : 1)
                if working { JcLoader(size: 14) }
            }
            .foregroundStyle(main ? .black : .white.opacity(0.85))
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(Capsule().fill(main ? Color.white : Color.white.opacity(0.12)))
            .opacity(locked ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(card.busy != nil)
        .animation(.easeOut(duration: 0.15), value: card.busy)
    }
}

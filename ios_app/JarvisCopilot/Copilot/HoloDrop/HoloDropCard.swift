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
        let host = UIHostingController(rootView: HoloArrivalCardsView(receiver: .shared))
        host.view.backgroundColor = .clear
        let w = PassThroughWindow(windowScene: scene)
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

/// A window whose empty space isn't there: a hit on its root view (the clear background)
/// goes to the window below.
final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

/// The stack of arrivals at the top of the screen. Swipe one up to dismiss it.
struct HoloArrivalCardsView: View {
    @ObservedObject var receiver: HoloDropReceiver

    var body: some View {
        VStack(spacing: 8) {
            ForEach(receiver.cards) { card in
                HoloArrivalCardView(card: card, receiver: receiver)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .animation(.spring(duration: 0.35), value: receiver.cards)
    }
}

struct HoloArrivalCardView: View {
    let card: HoloArrivalCard
    let receiver: HoloDropReceiver
    @State private var drag: CGFloat = 0

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
        .offset(y: min(0, drag))
        .gesture(DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { g in
                if g.translation.height < -40 { receiver.dismiss(card.id) } else { withAnimation(.spring) { drag = 0 } }
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
    private func chip(_ title: String, _ action: HoloAction, main: Bool) -> some View {
        Button { receiver.again(card.id, action) } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(main ? .black : .white.opacity(0.85))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Capsule().fill(main ? Color.white : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

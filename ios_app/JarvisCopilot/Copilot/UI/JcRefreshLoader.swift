import ObjectiveC
import SwiftUI
import UIKit

// JcRefreshLoader — pull-to-refresh shows the Jarvis loader instead of the system
// spinner, on every `.refreshable` screen, with no change at the call sites.
//
//   * While you pull, the logo's rings draw in step with your finger (ring A, then
//     ring B), and give a small pop once you've pulled far enough to refresh.
//   * While it refreshes, it's the animated JcLoader (JcLoaderStyle.default).
//   * As the refresh ends and the control folds away, the rings undraw with it.
//
// How: SwiftUI's `.refreshable` is a UIRefreshControl underneath. `install()` (once,
// at launch) adds a step to UIRefreshControl's layout: hide the system's spinner,
// keep one hosted `JcPullLoader` centred in the control, and feed it the pulled
// height (the control's height grows with the pull) and whether it is refreshing.
// To change how it looks, edit `JcPullLoader` below; the loader itself is JcLoader.

enum JcRefreshLoader {
    /// Call once at launch (JarvisCopilotApp.init).
    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIRefreshControl.self
        let original = #selector(UIView.layoutSubviews)
        let replacement = #selector(UIRefreshControl.jc_layoutSubviews)
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }
        // UIRefreshControl may inherit layoutSubviews from UIView: add it to the
        // subclass first so the swap never touches every other view's layout.
        if class_addMethod(cls, original, method_getImplementation(replacementMethod),
                           method_getTypeEncoding(replacementMethod)) {
            class_replaceMethod(cls, replacement, method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    @MainActor private static var installed = false
}

/// What the loader shows: how far you've pulled (points) and whether it refreshes.
@MainActor @Observable
final class JcPullState {
    var pull: CGFloat = 0
    var refreshing = false
}

/// The loader in the refresh control.
struct JcPullLoader: View {
    let state: JcPullState

    static let size: CGFloat = 28
    /// The pull (points) at which the rings are fully drawn — about where iOS
    /// starts the refresh.
    static let fullPull: CGFloat = 110

    var body: some View {
        let progress = min(1, max(0, Double((state.pull - 14) / (Self.fullPull - 14))))
        ZStack {
            if state.refreshing {
                JcLoader(size: Self.size)
                    .transition(.opacity)
            } else {
                Canvas { context, _ in Self.render(in: &context, size: Self.size, progress: progress) }
                    .frame(width: Self.size, height: Self.size)
                    .scaleEffect(progress >= 1 ? 1.08 : 0.82 + 0.18 * progress)
                    .opacity(min(1, progress * 3))
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: progress >= 1)
            }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .frame(width: Self.size + 8, height: Self.size + 8)
        .animation(.easeOut(duration: 0.18), value: state.refreshing)
    }

    /// The rings drawn up to `progress` (0...1): ring A over the first 60%, ring B
    /// from 40% to the end, the logo complete at 1.
    static func render(in context: inout GraphicsContext, size: CGFloat, progress: Double) {
        let stroke = JcLoaderGeometry.stroke(for: size)
        var faint = context
        faint.opacity = 0.18
        for (ring, from, to) in [(JcLoaderGeometry.ringA, 0.0, 0.6), (JcLoaderGeometry.ringB, 0.4, 1.0)] {
            let scaled = JcLoaderGeometry.scaled(ring, to: size)
            faint.stroke(scaled, with: .foreground, style: stroke)
            let drawn = min(1, max(0, (progress - from) / (to - from)))
            if drawn > 0.002 {
                context.stroke(scaled.trimmedPath(from: 0, to: drawn), with: .foreground, style: stroke)
            }
        }
    }
}

extension UIRefreshControl {
    private static var hostKey: UInt8 = 0
    private static var stateKey: UInt8 = 0

    /// Swapped in for layoutSubviews by `JcRefreshLoader.install()`: after the
    /// system lays the control out, this calls the original implementation.
    @objc func jc_layoutSubviews() {
        jc_layoutSubviews()          // the original layoutSubviews (swapped)
        jcLayoutLoader()
    }

    private func jcLayoutLoader() {
        let state: JcPullState
        let host: UIView
        if let s = objc_getAssociatedObject(self, &Self.stateKey) as? JcPullState,
           let h = objc_getAssociatedObject(self, &Self.hostKey) as? UIView {
            state = s
            host = h
        } else {
            state = JcPullState()
            let controller = UIHostingController(rootView: JcPullLoader(state: state))
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            controller.sizingOptions = []
            host = controller.view
            addSubview(host)
            objc_setAssociatedObject(self, &Self.stateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(self, &Self.hostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // Keep the hosting controller alive with its view.
            objc_setAssociatedObject(host, &Self.hostKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // The system's spinner (and anything else it draws) stays hidden.
        for view in subviews where view !== host { view.alpha = 0 }
        let side = JcPullLoader.size + 8
        host.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        bringSubviewToFront(host)
        // The pull comes from the scroll view's offset, every pixel of it: the
        // control isn't re-laid out on each scroll step (large-title pages above
        // all), so reading its height here alone left the rings stuck on a frame.
        if let scroll = superview as? UIScrollView {
            if objc_getAssociatedObject(self, &Self.observerKey) == nil {
                let observer = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                    MainActor.assumeIsolated { self?.jcFollowPull(of: scroll) }
                }
                objc_setAssociatedObject(self, &Self.observerKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            jcFollowPull(of: scroll)
        } else if state.pull != bounds.height {
            state.pull = bounds.height
        }
        if state.refreshing != isRefreshing { state.refreshing = isRefreshing }
    }

    private static var observerKey: UInt8 = 0

    /// The pull the loader is drawing (tests).
    var jcPull: CGFloat? { (objc_getAssociatedObject(self, &Self.stateKey) as? JcPullState)?.pull }

    /// How far past its resting top the scroll view is pulled, in points.
    private func jcFollowPull(of scroll: UIScrollView) {
        guard let state = objc_getAssociatedObject(self, &Self.stateKey) as? JcPullState else { return }
        let pull = max(0, -(scroll.contentOffset.y + scroll.adjustedContentInset.top))
        if state.pull != pull { state.pull = pull }
        if state.refreshing != isRefreshing { state.refreshing = isRefreshing }
    }
}

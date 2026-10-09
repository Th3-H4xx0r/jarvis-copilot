import SwiftUI

/// The Car page's two live cars, built in the background as the page opens: the hero on the page,
/// and one for the screens it opens (Controls, Climate, Status). A screen's car starts in the hero's
/// pose and glides overhead (and into the cabin) once the push has settled — one scene drawing at
/// a time, never the page's car stretched across a transition.
@MainActor
final class CarStage: ObservableObject {
    @Published private(set) var hero: CarModel.Live?
    @Published private(set) var screen: CarModel.Live?
    /// The build in flight: coming back to the page mid-build waits for it instead of starting a
    /// second 400 k-triangle build.
    private var building: Task<Void, Never>?

    func load() async {
        guard CarModel.hasBundledModel else { return }
        if building == nil {
            building = Task { [weak self] in
                let hero = await CarModel.build(.hero, spin: true, spinSeconds: 50)
                self?.hero = hero
                let screen = await CarModel.build(.hero, spin: false, canSlice: true)
                self?.screen = screen
            }
        }
        await building?.value
    }
}

/// One of the stage's cars at a stage. The hero turns while it's on screen; a screen's car resets
/// to the hero pose and glides to `at` once the push is done. It only redraws while something moves.
struct CarStageView: View {
    @ObservedObject var stage: CarStage
    let at: CarModel.Live.Stage
    var turnable = false
    var lit = false
    /// Called once a screen's car has glided into place (labels fade in then, not on a moving car).
    var onArrive: (() -> Void)? = nil

    @State private var onScreen = false
    /// True while the car turns or glides — the only time it needs redrawing every frame.
    @State private var moving = false
    @State private var settle: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var live: CarModel.Live? { at == .hero ? stage.hero : stage.screen }
    /// Lets the push slide in before the car starts to move.
    private static let pushSettle: Duration = .milliseconds(320)

    var body: some View {
        Group {
            if let live {
                SceneCanvas(scene: live.scene, camera: live.camera,
                            rendersContinuously: onScreen && scenePhase == .active && (at == .hero || moving),
                            preferredFramesPerSecond: 60,
                            onHorizontalPan: turnable && at == .hero ? { pan in CarSceneView.turn(live, pan) } : nil)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        // The car fades out at the top and bottom of its frame instead of being cut off by it.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                   .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeOut(duration: 0.3), value: live != nil)
        .onAppear {
            onScreen = true
            begin()
        }
        .onDisappear {
            onScreen = false
            settle?.cancel()
            if at == .hero { stage.hero?.setSpinning(false) }
        }
        .onChange(of: live != nil) { _, ready in if ready { begin() } }
        .onChange(of: lit) { _, on in live?.setLit(on) }
        .accessibilityHidden(true)
    }

    private func begin() {
        guard let live, onScreen else { return }
        live.setLit(lit)
        if at == .hero {
            live.setSpinning(true)
            return
        }
        // A screen's car always starts from the hero's pose, then glides once the push is done.
        // It draws every frame until it reports it has arrived (not a timer: leaving the app
        // mid-glide pauses drawing, and it carries on when the app comes back).
        live.go(to: .hero, animated: false)
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: Self.pushSettle)
            guard !Task.isCancelled else { return }
            moving = true
            live.go(to: at) {
                moving = false
                onArrive?()
            }
        }
    }
}

/// Lays labels over a top-view car: each car-space point becomes a position in the frame.
struct CarTopOverlay<Content: View>: View {
    @ObservedObject var stage: CarStage
    let at: CarModel.Live.Stage
    @ViewBuilder var content: (_ place: @escaping (SIMD3<Float>) -> CGPoint, _ landmarks: Landmarks) -> Content

    var body: some View {
        GeometryReader { geo in
            let landmarks = stage.screen?.landmarks ?? Landmarks(mesh: nil)
            let place: (SIMD3<Float>) -> CGPoint = { point in
                CarModel.Live.topViewPoint(point, in: geo.size,
                                           height: at == .cabin ? CarModel.Live.cabinHeight : CarModel.Live.topHeight,
                                           centreZ: landmarks.centreZ)
            }
            content(place, landmarks)
        }
    }
}

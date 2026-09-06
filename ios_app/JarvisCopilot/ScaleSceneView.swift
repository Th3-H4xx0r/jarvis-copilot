import SwiftUI
import SceneKit

struct ScaleSceneView: View {
    var state: ScaleVisualState
    var weightText: String?
    var entrance = true
    var presentation: ScaleModel.Presentation = .detail

    @State private var live: ScaleModel.Live?

    var body: some View {
        Group {
            if let live { ScaleSceneKitView(live: live, rendersContinuously: state == .measuring) }
            else { Color.clear }
        }
        .onAppear {
            guard live == nil else { return }
            let model = ScaleModel.Live(presentation: presentation)
            model.setDisplayText(weightText)
            model.setVisualState(state)
            if entrance { model.playEntrance() }
            live = model
        }
        .onChange(of: state) { _, newState in live?.setVisualState(newState) }
        .onChange(of: weightText) { _, text in live?.setDisplayText(text) }
    }
}

#if canImport(UIKit)
private struct ScaleSceneKitView: UIViewRepresentable {
    let live: ScaleModel.Live
    let rendersContinuously: Bool
    func makeUIView(context: Context) -> SCNView { configure(SCNView()) }
    func updateUIView(_ view: SCNView, context: Context) { view.rendersContinuously = rendersContinuously }
    private func configure(_ view: SCNView) -> SCNView {
        view.scene = live.scene
        view.pointOfView = live.camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = rendersContinuously
        return view
    }
}
#else
private struct ScaleSceneKitView: NSViewRepresentable {
    let live: ScaleModel.Live
    let rendersContinuously: Bool
    func makeNSView(context: Context) -> SCNView { configure(SCNView()) }
    func updateNSView(_ view: SCNView, context: Context) { view.rendersContinuously = rendersContinuously }
    private func configure(_ view: SCNView) -> SCNView {
        view.scene = live.scene
        view.pointOfView = live.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = rendersContinuously
        return view
    }
}
#endif

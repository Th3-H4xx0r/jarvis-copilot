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
            if let live { SceneCanvas(scene: live.scene, camera: live.camera, rendersContinuously: state == .measuring) }
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

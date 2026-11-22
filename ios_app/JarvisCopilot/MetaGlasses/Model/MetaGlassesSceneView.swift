import SwiftUI

/// The Ray-Ban Meta 3D model as a SwiftUI view (placeholder until the model task lands).
struct MetaGlassesSceneView: View {
    var spin: Bool = true
    var ledOn: Bool = false
    var folded: Bool = false

    var body: some View {
        Image(systemName: "eyeglasses")
            .font(.system(size: 54, weight: .light))
            .foregroundStyle(JcTheme.muted)
    }
}

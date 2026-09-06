import SwiftUI

/// Fullscreen image viewer opened by tapping a chat image. Ported from
/// `widgets/image_viewer.dart`: black canvas, transparent chrome, pinch-zoomable.
///
/// Takes an already-decoded `Image` (built from bytes the inline thumbnail
/// already fetched) so opening the viewer never triggers a re-fetch or re-decode.
struct ImageViewerPage: View {
    let image: Image
    /// Shown instead of the image when the caller had nothing to decode.
    var placeholder: String = "🖼 image"

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            image
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            // Clamp to the Flutter viewer's 0.8…5 range so a fling
                            // can't leave the image unrecoverably tiny or huge.
                            scale = min(max(scale * value, 0.8), 5)
                        }
                )
                .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2.5 }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "arrow.left") }
                    .tint(JcTheme.text)
            }
        }
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .animation(.snappy(duration: 0.2), value: scale)
    }
}

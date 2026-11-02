import Photos
import SwiftUI
import UIKit

/// Pictures in a reply, the way ChatGPT and Claude show them: one full width,
/// several as a 2-up grid of rounded tiles (an odd last one spans both
/// columns). Each tile holds its space while the bytes arrive — a saved chat
/// image's name carries its size — and a tap opens ``ChatImageViewer`` over
/// every picture of the reply.
struct ChatImageGallery: View {
    let images: [MarkdownImage]
    /// Every picture of the reply, in order — what the viewer pages through.
    var all: [MarkdownImage] = []

    @State private var viewing: ChatImageViewerStart?

    private static let spacing: CGFloat = 6
    private static let radius: CGFloat = 14

    var body: some View {
        Group {
            if images.count == 1, let only = images.first {
                ChatImageTile(image: only, fill: false, radius: Self.radius) { open(only) }
                    .frame(maxWidth: 480, alignment: .leading)
            } else {
                Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in
                                let image = rows[r][c]
                                ChatImageTile(image: image, fill: true, radius: Self.radius) { open(image) }
                                    .aspectRatio(rows[r].count == 1 ? 16 / 9 : 4 / 3, contentMode: .fit)
                                    .gridCellColumns(rows[r].count == 1 ? 2 : 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .fullScreenCover(item: $viewing) { start in
            ChatImageViewer(images: pages, start: start.index)
        }
    }

    private var pages: [MarkdownImage] { all.isEmpty ? images : all }

    private var rows: [[MarkdownImage]] {
        stride(from: 0, to: images.count, by: 2).map { Array(images[$0..<min($0 + 2, images.count)]) }
    }

    private func open(_ image: MarkdownImage) {
        viewing = ChatImageViewerStart(index: pages.firstIndex(of: image) ?? 0)
    }
}

/// Which picture a full-screen viewer opens on.
struct ChatImageViewerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// One picture: loads through ``ChatImageCache`` (cookie-gated `/api/media`),
/// a soft pulsing placeholder of the right shape until then, and an
/// "Image unavailable" tile with Retry if it can't load. Never shows a path.
struct ChatImageTile: View {
    let image: MarkdownImage
    /// Fill (and crop to) the cell, or fit the picture's own shape.
    var fill: Bool
    var radius: CGFloat = 12
    var onTap: () -> Void = {}

    @State private var loaded: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(image.caption.isEmpty ? "Image" : image.caption)
            .accessibilityAddTraits(.isImage)
            .task(id: "\(image.source)#\(attempt)") { await load() }
    }

    @ViewBuilder private var content: some View {
        if let loaded {
            Button(action: onTap) {
                if fill {
                    Color.clear.overlay(Image(uiImage: loaded).resizable().scaledToFill())
                } else {
                    Image(uiImage: loaded).resizable().scaledToFit()
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the picture full screen")
        } else if failed {
            Button { failed = false; attempt += 1 } label: {
                Label("Image unavailable · Retry", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(JcTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
            .buttonStyle(.plain)
            .background(JcTheme.surfaceAlt.opacity(0.5))
        } else {
            ChatImagePlaceholder()
                .modifier(ShapeOf(aspect: fill ? nil : (ChatMedia.aspect(of: image.source) ?? 4 / 3)))
        }
    }

    private func load() async {
        guard loaded == nil else { return }
        let data: Data?
        if let inline = ChatMedia.inlineImageData(image.source) {
            data = inline
        } else {
            data = await ChatImageCache.shared.bytes(image.source)
        }
        if let data, let ui = UIImage(data: data) {
            loaded = ui
        } else {
            failed = true
        }
    }

    /// Fit-mode placeholders take the picture's own shape when it's known.
    private struct ShapeOf: ViewModifier {
        let aspect: CGFloat?
        func body(content: Content) -> some View {
            if let aspect {
                content.aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity)
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A soft pulse in the tile's shape while the picture loads.
private struct ChatImagePlaceholder: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        JcTheme.surfaceAlt
            .opacity(dim ? 0.35 : 0.7)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Full screen over every picture of a reply: swipe between them, pinch or
/// double-tap to zoom, caption, Share and Save to Photos.
struct ChatImageViewer: View {
    let images: [MarkdownImage]
    @State private var index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: [Int: UIImage] = [:]
    @State private var note: String?

    init(images: [MarkdownImage], start: Int) {
        self.images = images
        _index = State(initialValue: min(max(start, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(images.indices, id: \.self) { i in
                    ZoomablePage(image: images[i]) { loaded[i] = $0 }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { caption }
        .statusBarHidden()
    }

    private var current: MarkdownImage? { images.indices.contains(index) ? images[index] : nil }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: { JcIcon("xmark") }
                .accessibilityLabel("Close")
            if images.count > 1 {
                Text("\(index + 1) / \(images.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            if let ui = loaded[index] {
                let title = (current?.caption).flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
                ShareLink(item: Image(uiImage: ui), preview: SharePreview(title, image: Image(uiImage: ui))) {
                    JcIcon("square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                Button { save(ui) } label: { JcIcon("square.and.arrow.down") }
                    .accessibilityLabel("Save to Photos")
            }
        }
        .tint(.white)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    @ViewBuilder private var caption: some View {
        let text = note ?? current?.caption ?? ""
        if !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, images.count > 1 ? 44 : 20)
        }
    }

    private func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in flash("Allow Photos access in Settings to save") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, _ in
                Task { @MainActor in flash(ok ? "Saved to Photos" : "Couldn't save") }
            }
        }
    }

    @MainActor private func flash(_ text: String) {
        withAnimation { note = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { note = nil }
        }
    }
}

/// One page of the viewer: the picture, pinch / double-tap to zoom, drag to pan
/// while zoomed.
private struct ZoomablePage: View {
    let image: MarkdownImage
    var onLoad: (UIImage) -> Void

    private var panGesture: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    @State private var ui: UIImage?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        Group {
            if let ui {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .gesture(MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            scale = min(max(scale * value, 1), 5)
                            if scale == 1 { offset = .zero }
                        })
                    // Panning only while zoomed, so it never steals the swipe
                    // between pictures.
                    .simultaneousGesture(scale > 1 ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            if scale == 1 { offset = .zero }
                        }
                    }
                    .accessibilityLabel(image.caption.isEmpty ? "Image" : image.caption)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: image.source) {
            let data: Data?
            if let inline = ChatMedia.inlineImageData(image.source) {
                data = inline
            } else {
                data = await ChatImageCache.shared.bytes(image.source)
            }
            if let data, let loaded = UIImage(data: data) {
                ui = loaded
                onLoad(loaded)
            }
        }
    }
}

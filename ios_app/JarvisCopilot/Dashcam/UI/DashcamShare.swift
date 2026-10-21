import SwiftUI

/// Save to Photos and Share… for what's on screen — both lenses in Both — with the progress while the
/// copies get ready (a clip only streamed is downloaded first) and how it went.
@MainActor
final class DashcamShareFlow: ObservableObject {
    enum Action { case photos, share }

    /// 0…1 while the copies get ready; nil otherwise.
    @Published private(set) var progress: Double?
    /// "Saved to Photos", or what went wrong.
    @Published private(set) var note: String?
    private var job: Task<Void, Never>?

    func run(_ action: Action, _ models: [DashcamPlayerModel]) {
        guard job == nil, !models.isEmpty else { return }
        note = nil
        progress = 0
        job = Task { [weak self] in
            DashcamExport.clear()
            do {
                var files: [URL] = []
                for (i, model) in models.enumerated() {
                    files.append(try await model.exportFile { p in self?.progress = (Double(i) + p) / Double(models.count) })
                }
                switch action {
                case .share:
                    DashcamExport.share(files)
                case .photos:
                    try await DashcamExport.saveToPhotos(zip(files, models).map {
                        DashcamExport.PhotosItem(file: $0, clip: $1.clip, fixes: $1.fixes)
                    })
                    DashcamExport.clear()
                    self?.say(files.count == 1 ? "Saved to Photos" : "Saved \(files.count) clips to Photos")
                }
            } catch is CancellationError {
                DashcamExport.clear()
            } catch let error as URLError where error.code == .cancelled {
                DashcamExport.clear()
            } catch {
                DashcamExport.clear()
                self?.say(error.localizedDescription)
            }
            self?.progress = nil
            self?.job = nil
        }
    }

    func cancel() { job?.cancel() }

    /// Shown for a few seconds under the clip.
    private func say(_ text: String) {
        note = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.note == text { self?.note = nil }
        }
    }
}

/// The flow's progress or how it went, as a pill (the full-screen view has no caption row of its own).
struct DashcamShareNote: View {
    @ObservedObject var flow: DashcamShareFlow

    var body: some View {
        if let text = flow.progress.map({ "Getting the clip ready… \(Int($0 * 100))%" }) ?? flow.note {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 70)
                .allowsHitTesting(false)
        }
    }
}

/// The share button: a menu of Save to Photos and Share…; while the copies get ready, a ring that
/// fills (tap it to stop).
struct DashcamShareButton: View {
    @ObservedObject var flow: DashcamShareFlow
    let models: [DashcamPlayerModel]
    /// Over full-screen video: white, in the same glass pill as the close button beside it.
    var overVideo = false

    private var side: CGFloat { overVideo ? 40 : 34 }
    private var tint: Color { overVideo ? .white : JcTheme.accent }

    var body: some View {
        if let p = flow.progress {
            styled(Button { flow.cancel() } label: { chrome(ring(p)) })
                .accessibilityLabel("Stop getting the clip ready")
        } else {
            styled(Menu {
                Button { flow.run(.photos, models) } label: {
                    Label(models.count > 1 ? "Save Both to Photos" : "Save to Photos", systemImage: "square.and.arrow.down")
                }
                Button { flow.run(.share, models) } label: {
                    Label(models.count > 1 ? "Share Both…" : "Share…", systemImage: "square.and.arrow.up")
                }
            } label: {
                chrome(JcIcon("square.and.arrow.up", size: overVideo ? 16 : 15).foregroundStyle(tint))
            })
            .accessibilityLabel("Share")
        }
    }

    private func ring(_ p: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.04, p))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: p)
            JcIcon("xmark", size: 9).foregroundStyle(tint)
        }
        .frame(width: 20, height: 20)
    }

    /// The glass: a circle as the toolbar's other buttons, or the full-screen view's pill (its style's).
    @ViewBuilder private func chrome(_ content: some View) -> some View {
        if overVideo {
            content.frame(width: side, height: side)
        } else {
            content.frame(width: side, height: side).jcLiquidGlass(in: Circle())
        }
    }

    @ViewBuilder private func styled(_ control: some View) -> some View {
        if overVideo { control.buttonStyle(.jcGlass(compact: true)) } else { control.buttonStyle(.plain) }
    }
}

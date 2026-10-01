import SwiftUI

/// The creator's designs: the App Group cache, saved through `WidgetSync`.
@MainActor
final class WidgetDesignStore: ObservableObject {
    static let shared = WidgetDesignStore(sync: .shared)

    @Published private(set) var designs: [WidgetDesignInfo] = []

    private let sync: WidgetSync
    private let directory: URL?

    init(sync: WidgetSync, directory: URL? = WidgetDesignCache.directory) {
        self.sync = sync
        self.directory = directory
        reload()
    }

    func reload() {
        designs = WidgetDesignCache.infos(in: directory)
    }

    func design(_ id: String) -> JCDesign? { WidgetDesignCache.load(id, in: directory) }

    /// The builder layout, or nil for a design written by hand (by Jarvis).
    func draft(_ id: String) -> WidgetDesignDraft? {
        WidgetDesignCache.rawJSON(id, in: directory).flatMap(WidgetDesignDraft.init(json:))
    }

    func save(_ draft: WidgetDesignDraft) async -> WidgetSync.SaveOutcome {
        let outcome: WidgetSync.SaveOutcome
        do {
            outcome = try await sync.save(draft.compile())
        } catch {
            outcome = .rejected(error.localizedDescription)
        }
        reload()
        return outcome
    }

    func delete(_ id: String) async {
        await sync.delete(id)
        reload()
    }

    func refresh() async {
        await sync.sync()
        reload()
    }
}

/// How big each size is drawn in the creator — close to an iPhone's own widget sizes.
enum WidgetPreviewSize {
    static func points(_ size: WidgetSize) -> CGSize {
        switch size {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 360, height: 170)
        case .large: return CGSize(width: 360, height: 380)
        case .extraLarge: return CGSize(width: 360, height: 380)
        case .circular: return CGSize(width: 76, height: 76)
        case .rectangular: return CGSize(width: 172, height: 76)
        case .inline: return CGSize(width: 240, height: 28)
        }
    }
}

/// A design drawn the way the widget draws it, at one size, with the data the widgets have now.
struct WidgetPreview: View {
    let design: JCDesign?
    let size: WidgetSize
    let data: [String: JCJSON]

    var body: some View {
        let frame = WidgetPreviewSize.points(size)
        let node = design?.node(for: size)
        ZStack {
            if size.isLockScreen {
                RoundedRectangle(cornerRadius: size == .circular ? frame.width / 2 : 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            }
            if let node {
                JCDesignRenderer(tint: design.flatMap { jcParseColor($0.tint) } ?? JcAccent.color)
                    .render(node, JCBindingContext(data: data))
                    .padding(size.isLockScreen ? 6 : 14)
                    .frame(width: frame.width, height: frame.height)
            } else {
                Text(design == nil ? "No design" : "Not designed for this size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipped()
    }
}

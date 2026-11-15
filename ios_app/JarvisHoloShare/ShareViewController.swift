import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Jarvis" in the share sheet → Holo Drop: the Orbit with your devices around what you're
/// sharing; fling it toward one or tap one. Uses the paired server's credentials from the
/// team Keychain group (VaultShareKeychain), like the vault share.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let root = HoloShareRoot(context: extensionContext)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .black
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct HoloShareRoot: View {
    weak var context: NSExtensionContext?
    @State private var model: HoloOrbitModel?
    @State private var problem: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let model {
                HoloOrbitView(model: model)
                    .onChange(of: model.settled) { _, settled in
                        if settled { closeSoon() }
                    }
            } else if let problem {
                Text(problem).foregroundStyle(.white).multilineTextAlignment(.center).padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.1)))
            }
            .padding(14)
        }
        .task { await start() }
    }

    private func start() async {
        guard let server = VaultShareKeychain.loadServer(), let base = URL(string: server.baseURL) else {
            problem = "Open Jarvis on this iPhone once so Holo Drop can reach your server."
            return
        }
        guard let item = await HoloShareItems.first(in: context) else {
            problem = "Nothing here Holo Drop can send."
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let client = HoloDropClient(baseURL: base, headers: server.headers, session: URLSession(configuration: config))
        model = HoloOrbitModel(item: item, client: client)
    }

    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { close() }
    }

    private func close() {
        context?.completeRequest(returningItems: nil)
    }
}

/// The first shareable thing in the extension's input: a web link, text, or a file.
enum HoloShareItems {
    static func first(in context: NSExtensionContext?) async -> HoloItem? {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let title = (context?.inputItems.first as? NSExtensionItem)?.attributedContentText?.string
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, url.scheme?.hasPrefix("http") == true {
                return .link(url, title: title)
            }
        }
        for (type, kind) in [(UTType.image, "image"), (UTType.movie, "video"), (UTType.data, "file")] {
            for p in providers where p.hasItemConformingToTypeIdentifier(type.identifier) {
                if let file = await copy(p, type: type) {
                    let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    return .file(file, name: file.lastPathComponent, mime: mime, kind: kind)
                }
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
                if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true { return .link(url, title: nil) }
                return .text(text)
            }
        }
        return nil
    }

    /// The provider's file, copied into the extension's temp folder (streamed, never in memory).
    private static func copy(_ p: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                do { try FileManager.default.copyItem(at: url, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(returning: nil) }
            }
        }
    }
}

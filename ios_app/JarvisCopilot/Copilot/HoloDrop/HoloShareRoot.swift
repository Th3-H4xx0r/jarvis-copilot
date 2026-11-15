import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Holo Drop share screen (the Orbit around what's being shared), used by both share
/// options: "Holo Drop" and the main Jarvis one (which opens Holo Drop first, Vault one tap away).
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
        // The copy made for this share is done with.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop"))
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
        // Images and videos first, then plain text (text also counts as "data", so it must come
        // before the any-file case or a text selection would arrive as a .txt file).
        for (type, kind) in [(UTType.image, "image"), (UTType.movie, "video")] {
            for p in providers where p.hasItemConformingToTypeIdentifier(type.identifier) {
                if let item = await fileItem(p, type: type, kind: kind) { return item }
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
                if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true { return .link(url, title: nil) }
                return .text(text)
            }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            if let item = await fileItem(p, type: .data, kind: "file") { return item }
        }
        return nil
    }

    private static func fileItem(_ p: NSItemProvider, type: UTType, kind: String) async -> HoloItem? {
        guard let file = await copy(p, type: type) else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .file(file, name: file.lastPathComponent, mime: mime, kind: kind)
    }

    /// The provider's file, copied into the extension's temp folder (streamed, never in memory).
    private static func copy(_ p: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HoloDrop/\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                do { try FileManager.default.copyItem(at: url, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(returning: nil) }
            }
        }
    }
}

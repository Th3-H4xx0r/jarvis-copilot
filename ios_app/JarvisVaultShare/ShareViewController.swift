import QuickLookThumbnailing
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Save to Vault" in the share sheet. Write-only: it uploads to `/api/vault/inbox` with the
/// paired server's credentials and can never read anything back. It knows nothing about what's
/// in the vault — not even folder names — so everything lands in the vault's top folder, to be
/// filed from the app after Face ID.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareRootView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// One thing being shared.
enum SharePayload {
    case link(URL)
    case text(String)
    case file(URL)
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, saving(Double), saved, failed(String) }

    @Published var phase: Phase = .loading
    @Published private(set) var payloads: [SharePayload] = []
    @Published private(set) var preview: UIImage?
    @Published private(set) var summary = ""

    private let server: VaultShareKeychain.Server?
    private weak var context: NSExtensionContext?
    private let session: URLSession

    init(context: NSExtensionContext?) {
        self.context = context
        server = VaultShareKeychain.loadServer()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        Task { await collect() }
    }

    var canSave: Bool { phase == .ready && server != nil && !payloads.isEmpty }

    func cancel() {
        cleanUp()
        context?.cancelRequest(withError: NSError(domain: "JarvisVault", code: 0))
    }

    // MARK: Collect

    private func collect() async {
        guard server != nil else {
            phase = .failed("Open Jarvis once (paired to your server) and try again.")
            return
        }
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var out: [SharePayload] = []
        for p in providers {
            if let payload = await load(p) { out.append(payload) }
        }
        payloads = out
        summary = Self.describe(out)
        if case .file(let url)? = out.first(where: { if case .file = $0 { return true } else { return false } }) {
            preview = await Self.thumbnail(url).flatMap(UIImage.init(data:))
        }
        phase = out.isEmpty ? .failed("Nothing here the vault can keep.") : .ready
    }

    private func load(_ p: NSItemProvider) async -> SharePayload? {
        // A photo, video or PDF shared as such goes in as that file.
        for type in [UTType.movie, .image, .pdf] where p.hasItemConformingToTypeIdentifier(type.identifier) {
            if let url = await copyFile(p, type: type) { return .file(url) }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            if url.isFileURL { return copy(url).map { .file($0) } }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .link(url) }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               !trimmed.contains(" ") {
                return .link(url)
            }
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
        // Any other document from Files.
        if p.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           let url = await copyFile(p, type: .data) {
            return .file(url)
        }
        return nil
    }

    private func copyFile(_ p: NSItemProvider, type: UTType) async -> URL? {
        let identifier = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
        return await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                cont.resume(returning: url.flatMap { self.copy($0) })
            }
        }
    }

    nonisolated private func copy(_ url: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }

    private static func describe(_ payloads: [SharePayload]) -> String {
        if payloads.count == 1 {
            switch payloads[0] {
            case .link(let url): return url.host ?? url.absoluteString
            case .text(let t): return String(t.prefix(80))
            case .file(let url): return url.lastPathComponent
            }
        }
        return "\(payloads.count) items"
    }

    // MARK: Save

    func save() async {
        guard let server, let base = URL(string: server.baseURL) else { return }
        phase = .saving(0)
        do {
            for (i, payload) in payloads.enumerated() {
                let done = Double(i) / Double(payloads.count)
                switch payload {
                case .link(let url):
                    _ = try await json("POST", "/inbox", ["kind": "link", "url": url.absoluteString],
                                       base: base, server: server)
                case .text(let text):
                    let title = String(text.split(separator: "\n").first ?? "").prefix(60)
                    _ = try await json("POST", "/inbox", ["kind": "note", "title": String(title), "body": text], base: base, server: server)
                case .file(let url):
                    try await upload(url, base: base, server: server) { part in
                        self.phase = .saving(done + part / Double(self.payloads.count))
                    }
                }
            }
            phase = .saved
            cleanUp()
            try? await Task.sleep(for: .milliseconds(900))
            context?.completeRequest(returningItems: nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func cleanUp() {
        for case .file(let url) in payloads {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func request(_ method: String, _ path: String, base: URL, server: VaultShareKeychain.Server,
                         body: Data?, contentType: String?) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("api/vault" + path), timeoutInterval: 180)
        req.httpMethod = method
        for (k, v) in server.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw NSError(domain: "JarvisVault", code: status,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? "The server said \(status)."])
        }
        return data
    }

    private func json(_ method: String, _ path: String, _ body: [String: Any], base: URL,
                      server: VaultShareKeychain.Server) async throws -> [String: Any] {
        let data = try await send(request(method, path, base: base, server: server,
                                          body: try JSONSerialization.data(withJSONObject: body),
                                          contentType: "application/json"))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func upload(_ url: URL, base: URL, server: VaultShareKeychain.Server,
                        progress: @escaping @MainActor (Double) -> Void) async throws {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind = type.conforms(to: .pdf) ? "pdf" : type.conforms(to: .image) ? "image"
            : (type.conforms(to: .movie) || type.conforms(to: .video)) ? "video" : "file"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let start = try await json("POST", "/inbox/uploads",
                                   ["kind": kind, "filename": url.lastPathComponent,
                                    "mime": type.preferredMIMEType ?? "application/octet-stream", "size": size,
                                    "title": url.deletingPathExtension().lastPathComponent],
                                   base: base, server: server)
        guard let id = start["upload_id"] as? String else {
            throw NSError(domain: "JarvisVault", code: 0, userInfo: [NSLocalizedDescriptionKey: "The upload didn't start."])
        }
        let chunk = max(1, (start["chunk_size"] as? NSNumber)?.intValue ?? 8 * 1024 * 1024)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let count = max(1, (size + chunk - 1) / chunk)
        for index in 0..<count {
            try handle.seek(toOffset: UInt64(index * chunk))
            let data = try handle.read(upToCount: chunk) ?? Data()
            var attempt = 0
            while true {
                do {
                    _ = try await send(request("PUT", "/inbox/uploads/\(id)/\(index)", base: base, server: server,
                                               body: data, contentType: "application/octet-stream"))
                    break
                } catch {
                    attempt += 1
                    if attempt >= 3 { throw error }
                    try await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
            progress(Double(index + 1) / Double(count))
        }
        if let thumb = await Self.thumbnail(url) {
            _ = try? await send(request("PUT", "/inbox/uploads/\(id)/thumb", base: base, server: server,
                                        body: thumb, contentType: "image/jpeg"))
        }
        _ = try await send(request("POST", "/inbox/uploads/\(id)/finish", base: base, server: server,
                                   body: Data("{}".utf8), contentType: "application/json"))
    }

    static func thumbnail(_ url: URL) async -> Data? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 640, height: 640), scale: 1,
                                               representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return rep.uiImage.jpegData(compressionQuality: 0.78)
    }
}

/// The sheet: what's going in, where it goes, Save. Same black-and-white look as the app.
struct ShareRootView: View {
    @ObservedObject var model: ShareModel

    private let text = Color(red: 0xED / 255, green: 0xF0 / 255, blue: 0xF8 / 255)
    private let muted = Color(red: 0x8A / 255, green: 0x93 / 255, blue: 0xA8 / 255)
    private let fill = Color.white.opacity(0.07)
    private let hairline = Color.white.opacity(0.08)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                card
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                    Text("Saved encrypted to your vault. File it into a folder from Jarvis later.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(muted)
                .padding(.horizontal, 4)
                .padding(.top, 12)

                status.padding(.top, 16)
                Spacer(minLength: 0)
                Button { Task { await model.save() } } label: {
                    Text(model.phase == .saved ? "Saved" : "Save to Vault")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSave)
                .opacity(model.canSave || model.phase == .saved ? 1 : 0.4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Save to Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }.foregroundStyle(text)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// What's being saved: its picture (or a glyph for a link or note) and its name.
    private var card: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06))
                if let img = model.preview {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: glyph).font(.system(size: 22, weight: .regular)).foregroundStyle(muted)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.summary.isEmpty ? "Getting ready…" : model.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(text)
                    .lineLimit(2)
                Text(kindLine)
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.circle")
                .font(.system(size: 14)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
        case .saving(let p):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: p).tint(text)
                Text("Encrypting and uploading…").font(.system(size: 13)).foregroundStyle(muted)
            }
        case .saved:
            Label("Saved to your vault", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(text)
        default:
            EmptyView()
        }
    }

    private var glyph: String {
        switch model.payloads.first {
        case .link?: return "link"
        case .text?: return "note.text"
        default: return "doc"
        }
    }

    private var kindLine: String {
        let p = model.payloads
        if p.count > 1 { return "\(p.count) items" }
        switch p.first {
        case .link?: return "Link · preview made on your server"
        case .text?: return "Note"
        case .file(let url)?:
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "File" : ext
        case nil: return ""
        }
    }
}

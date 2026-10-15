import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The week with the agents, in its own window (menu bar → Weekly recap).
/// "Save image" writes the same card at 1080×1920 for sharing.
@MainActor
enum RecapWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Your week"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RecapScreen(origin: model.apiOrigin))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
    }
}

private struct RecapScreen: View {
    let origin: String?
    @State private var recap: MacRecap?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let recap {
                if recap.isEmpty {
                    Spacer()
                    Text("A quiet week — no agent turns in the last seven days.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    RecapCardView(recap: recap, forImage: false).padding(24)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button("Save image…") { save(recap) }
                    }
                    .padding(16)
                }
            } else if let error {
                Spacer()
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .frame(minWidth: 420, minHeight: 620)
        .background(Color.black)
        .task { await load() }
    }

    private func load() async {
        guard let origin, let url = MacRecap.recapURL(origin: origin) else {
            error = "Jarvis isn't connected on this Mac (jc-client)."
            return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "The server didn't send a recap."
                return
            }
            recap = MacRecap(json: json)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ recap: MacRecap) {
        let card = RecapCardView(recap: recap, forImage: true)
            .padding(28).frame(width: 360, height: 640).background(Color.black)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Jarvis week.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

struct RecapCardView: View {
    let recap: MacRecap
    let forImage: Bool

    private let accent = JcAccent.color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if forImage {
                    Text("MY WEEK WITH THE AGENTS").font(.system(size: 12, weight: .bold)).tracking(1.2)
                        .foregroundStyle(accent)
                }
                Text(recap.time).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("of agent time · \(recap.sessions) session\(recap.sessions == 1 ? "" : "s")")
                    .foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                tile("\(recap.files)", "files changed")
                tile("+\(recap.added) −\(recap.removed)", "lines")
                tile("\(recap.commands)", "commands run")
                tile("\(recap.approved)", recap.denied > 0 ? "approved · \(recap.denied) denied" : "approved")
                if recap.answered > 0 { tile("\(recap.answered)", "questions answered") }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(recap.highlights, id: \.label) { h in
                    HStack {
                        Image(systemName: h.icon).foregroundStyle(accent).frame(width: 18)
                        Text(h.label).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(h.value).fontWeight(.semibold).foregroundStyle(.white).lineLimit(1)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.06)))
            if forImage { Spacer(minLength: 0) }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }
}

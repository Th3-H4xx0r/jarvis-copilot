import AppKit
import SwiftUI

/// The island chat's pieces, after the iPhone's chat (MessageRow,
/// AssistantTurnCard, ToolRow, MarkdownText) at island size, on the island's
/// black.
enum ChatStyle {
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)
    static let danger = Color(red: 1, green: 0.42, blue: 0.38)
    static let codeFill = Color(red: 0x11 / 255, green: 0x14 / 255, blue: 0x18 / 255)
    static let body: CGFloat = 13.5
}

extension View {
    /// The phone's liquid glass on a shape (a quiet white wash under it, so it
    /// reads the same on the island's black and before macOS 26).
    @ViewBuilder
    func chatGlass<S: InsettableShape>(in shape: S) -> some View {
        let base = self.background(shape.fill(Color.white.opacity(0.07)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        if #available(macOS 26.0, *) {
            base.glassEffect(.regular.interactive(), in: shape)
        } else {
            base
        }
    }
}

// MARK: - Rows

/// Your turn: a soft accent surface hugged to the right, what went with it underneath.
struct ChatUserBubble: View {
    let line: MacChatStore.Line

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                Text(line.text).font(.system(size: ChatStyle.body)).lineSpacing(2.5).foregroundStyle(ChatStyle.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !line.files.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(line.files, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.system(size: 9))
                                Text(name).font(.system(size: 10.5)).lineLimit(1)
                            }
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.10)))
                        }
                    }
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            .background(shape.fill(JcAccent.soft.opacity(0.13)))
            .overlay(shape.strokeBorder(JcAccent.soft.opacity(0.10), lineWidth: 0.5))
        }
    }
}

/// A muted line between turns (a file that couldn't go).
struct ChatNoteRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(ChatStyle.muted)
    }
}

/// Jarvis's turn: no bubble — a quiet label, its tools in one box, the reply.
struct ChatTurnView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10.5, weight: .medium)).foregroundStyle(JcAccent.color)
                Text("Jarvis").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            if !turn.tools.isEmpty {
                let box = RoundedRectangle(cornerRadius: 12, style: .continuous)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turn.tools) { ChatToolRowView(tool: $0) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(box.fill(Color.white.opacity(0.035)))
                .overlay(box.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
            }
            if turn.hasText { ChatMarkdownView(text: turn.text) }
            if turn.showsDots { ChatThinkingDots().padding(.vertical, 3) }
            if let error = turn.error { errorText(error) }
            if turn.stopped {
                Label("Stopped", systemImage: "stop.circle").font(.system(size: 11.5)).foregroundStyle(ChatStyle.muted)
            }
            if let note = turn.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(ChatStyle.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(ChatStyle.danger).frame(width: 2)
            Text(text).font(.system(size: 12)).foregroundStyle(ChatStyle.danger).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
            Spacer(minLength: 0)
        }
        .background(ChatStyle.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// One tool call: spinner → check, the name, one grey line, the time; click
/// to see its arguments and result.
struct ChatToolRowView: View {
    let tool: ChatTool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard tool.hasDetail else { return }
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: { header }
                .buttonStyle(.plain)
            if expanded, tool.hasDetail {
                VStack(alignment: .leading, spacing: 7) {
                    if !tool.args.isEmpty { ChatCodeBox(label: "Arguments", text: tool.args) }
                    let result = (tool.result ?? tool.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty { ChatCodeBox(label: "Result", text: result) }
                }
                .padding(.leading, 20).padding(.top, 6)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if tool.done {
                    Image(systemName: tool.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(tool.isError ? ChatStyle.danger : JcAccent.color)
                } else {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                }
            }
            .frame(width: 13, height: 13, alignment: .leading)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.shortName).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatStyle.text).lineLimit(1)
                let line = tool.detailLine
                if !line.isEmpty {
                    Text(line).font(.system(size: 10.5)).foregroundStyle(ChatStyle.muted).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 4)
            if let d = tool.durationText {
                Text(d).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(ChatStyle.faint)
            }
            if tool.hasDetail {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ChatStyle.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A labelled monospaced block (a tool's arguments or result), clipped at
/// 4 000 characters like the phone's.
struct ChatCodeBox: View {
    let label: String
    let text: String
    static let limit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).kerning(0.6).foregroundStyle(ChatStyle.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.count > Self.limit ? String(text.prefix(Self.limit)) + "\n…" : text)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(ChatStyle.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatStyle.codeFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
    }
}

/// Three dots rising in turn — still working.
struct ChatThinkingDots: View {
    var size: CGFloat = 6
    @State private var phase = false

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(ChatStyle.muted).frame(width: size, height: size)
                    .offset(y: phase ? -size * 0.6 : size * 0.3)
                    .opacity(phase ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.16),
                               value: phase)
            }
        }
        .frame(height: size * 2.2)
        .onAppear { phase = true }
    }
}

// MARK: - Approvals and questions

/// A command waiting on your yes. The turn carries on once you answer.
struct ChatApprovalCard: View {
    let approval: ChatApproval
    var error: String?
    let answer: (ChatApproval.Choice) -> Void

    var body: some View {
        ChatCard(icon: "lock.shield", title: "Allow this command?") {
            if !approval.description.isEmpty {
                Text(approval.description.prefix(1).uppercased() + approval.description.dropFirst())
                    .font(.system(size: 11.5)).foregroundStyle(ChatStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !approval.command.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(approval.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ChatStyle.text)
                        .lineLimit(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatStyle.codeFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(ChatStyle.danger) }
            HStack(spacing: 6) {
                ChatPillButton(title: "Allow once", color: JcAccent.color, strong: true) { answer(.once) }
                ChatPillButton(title: "Always allow", color: ChatStyle.text) { answer(.always) }
                    .help("Allow this kind of command from now on")
                Spacer(minLength: 0)
                ChatPillButton(title: "Deny", color: ChatStyle.danger) { answer(.deny) }
            }
            .padding(.top, 2)
        }
    }
}

/// Jarvis's question: its choices, or your own words.
struct ChatClarifyCard: View {
    let clarify: ChatClarify
    var error: String?
    let answer: (String) -> Void
    @State private var typed = ""

    var body: some View {
        ChatCard(icon: "questionmark.bubble", title: "Jarvis asks") {
            Text(clarify.question).font(.system(size: ChatStyle.body)).foregroundStyle(ChatStyle.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !clarify.choices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(clarify.choices.enumerated()), id: \.offset) { _, choice in
                        Button { answer(choice) } label: {
                            HStack(spacing: 8) {
                                Text(choice).font(.system(size: 12.5)).foregroundStyle(ChatStyle.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(JcAccent.color)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .chatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Or type an answer", text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(ChatStyle.text)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(typed.trimmingCharacters(in: .whitespaces).isEmpty ? ChatStyle.faint : JcAccent.color)
                        .frame(width: 24, height: 24)
                        .chatGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 11).padding(.trailing, 4).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(ChatStyle.danger) }
        }
    }

    private func submit() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        answer(t)
    }
}

/// The card both prompts sit in: the tool box's surface with an accent edge.
private struct ChatCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(JcAccent.color)
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(JcAccent.color.opacity(0.05)))
        .overlay(shape.strokeBorder(JcAccent.color.opacity(0.35), lineWidth: 0.75))
    }
}

/// A glass pill with its colour in the label.
struct ChatPillButton: View {
    let title: String
    let color: Color
    var strong = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: strong ? .semibold : .medium)).foregroundStyle(color)
                .padding(.horizontal, 12).frame(height: 28)
                .chatGlass(in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Markdown

/// A reply's markdown, block by block, `MEDIA:` lines drawn as pictures.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: ChatStyle.body))
        .foregroundStyle(ChatStyle.text)
        .tint(JcAccent.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: ChatMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ChatMarkdown.inline(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15.5 : 14, weight: .bold))
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).monospacedDigit().foregroundStyle(ChatStyle.muted)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(ChatMarkdown.inline(item.text)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 12)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(JcAccent.color.opacity(0.6)).frame(width: 3)
                Text(ChatMarkdown.inline(text)).foregroundStyle(ChatStyle.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
        case .image(let alt, let source):
            ChatImageView(alt: alt, source: source)
        case .table(let table):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, h in
                            Text(ChatMarkdown.inline(h)).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(ChatMarkdown.inline(cell)).font(.system(size: 12)).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// A fenced code block with a copy button.
struct ChatCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language.lowercased()).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ChatStyle.muted)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? JcAccent.color : ChatStyle.muted)
                }
                .buttonStyle(.plain).help("Copy")
            }
            .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ChatStyle.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9).padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChatStyle.codeFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Images

/// A picture in a reply: fetched (server paths through the island's API
/// origin, which carries the session), fitted to the column, rounded; a click
/// opens it full size.
struct ChatImageView: View {
    let alt: String
    let source: String
    @State private var loaded: NSImage?
    @State private var failed = false

    static let maxHeight: CGFloat = 240

    var body: some View {
        if let image = loaded ?? ChatImageCache.shared.cached(source) {
            // As wide as the column allows, never taller than maxHeight, never upscaled.
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .frame(maxWidth: max(40, min(image.size.width, Self.maxHeight * aspect)), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { ChatImageCache.shared.open(source) }
                .help("Open full size")
        } else if failed {
            Label(alt.isEmpty || alt == "image" ? "Image didn't load" : alt, systemImage: "photo")
                .font(.system(size: 11.5)).foregroundStyle(ChatStyle.muted)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .onTapGesture { ChatImageCache.shared.open(source) }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05))
                .frame(maxWidth: 320).frame(height: 160)
                .overlay(ProgressView().controlSize(.small))
                .task(id: source) {
                    loaded = await ChatImageCache.shared.image(source)
                    failed = loaded == nil
                }
        }
    }
}

/// Chat images, kept in memory (they may be private: nothing on disk until
/// you open one).
@MainActor
final class ChatImageCache {
    static let shared = ChatImageCache()
    static let maxBytes = 24 * 1024 * 1024

    private let images = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init() { images.totalCostLimit = 64 * 1024 * 1024 }

    func cached(_ source: String) -> NSImage? {
        if let hit = images.object(forKey: source as NSString) { return hit }
        guard let d = ChatMedia.inlineData(source), let image = NSImage(data: d) else { return nil }
        images.setObject(image, forKey: source as NSString, cost: d.count)
        return image
    }

    func image(_ source: String) async -> NSImage? {
        if let hit = cached(source) { return hit }
        if let running = inFlight[source] { return await running.value.flatMap(NSImage.init(data:)) }
        guard let url = ChatMedia.url(for: source, origin: AppModel.shared.apiOrigin) else { return nil }
        let task = Task<Data?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60)),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count <= Self.maxBytes
            else { return nil }
            return data
        }
        inFlight[source] = task
        let data = await task.value
        inFlight[source] = nil
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: source as NSString, cost: data.count)
        return image
    }

    /// Full size: a web picture in the browser; one from Jarvis (or inline)
    /// in Preview, from a temporary copy.
    func open(_ source: String) {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: source) {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            guard let image = await image(source),
                  let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-chat-images", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("image-\(abs(source.hashValue)).png")
            guard (try? png.write(to: file)) != nil else { return }
            NSWorkspace.shared.open(file)
        }
    }
}

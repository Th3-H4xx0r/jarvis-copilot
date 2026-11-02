import SwiftUI

/// Renders a streamed markdown reply, ported from `widgets/markdown_stream.dart`.
///
/// Two layers: ``MarkdownBlocks`` splits the text into blocks (pure, unit
/// tested), and `AttributedString(markdown:)` does the inline styling inside each
/// one — bold, italics, links and inline code — which is exactly what
/// `Esp32ChatView.rendered(_:)` does today, only per block instead of per turn.
///
/// The view stays a pure function of the text — no buffer to get out of sync
/// mid-stream — but the parse itself is memoised on that text by
/// ``ChatMarkdownCache``: SwiftUI re-evaluates this `body` once per streamed
/// token, and re-parsing the whole reply each time is quadratic work
/// (swift-correctness H7).
struct ChatMarkdownText: View {
    let text: String
    /// The main chat's live HTML pages and link previews. Off elsewhere (agent
    /// transcripts, skill docs): their paths aren't files on the server.
    var embeds = false

    var body: some View {
        let blocks = ChatMarkdownCache.blocks(for: rendered, embeds: embeds)
        let images = MarkdownBlocks.images(in: blocks)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block, images: images)
            }
        }
        .font(.body)
        .foregroundStyle(JcTheme.text)
        .tint(JcTheme.cyan)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The `MEDIA:<ref>` pre-pass `markdown_stream.dart` runs before rendering:
    /// the agent's image-generation directives are not markdown, so without this
    /// they show up as raw `MEDIA:/tmp/…` text.
    private var rendered: String {
        ChatMedia.rewrite(text, base: ChatMedia.apiBase())
    }

    @ViewBuilder private func view(for block: MarkdownBlock, images all: [MarkdownImage]) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(chatInlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: .bold))
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(chatInlineMarkdown(text))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let text, _):
            ChatCodeBlock(language: language, code: text)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            if !item.text.isEmpty {
                                Text(chatInlineMarkdown(item.text))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.images.isEmpty {
                                ChatImageGallery(images: item.images, all: all)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(JcTheme.cyan.opacity(0.6)).frame(width: 3)
                Text(chatInlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)

        case .gallery(let images):
            ChatImageGallery(images: images, all: all)

        case .table(let table):
            ChatMarkdownTable(table: table)

        case .htmlPage(let path):
            ChatHTMLCard(path: path)

        case .linkPreview(let url):
            if let link = URL(string: url) {
                ChatLinkPreview(url: link)
            } else {
                Text(url).textSelection(.enabled)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 17
        default: return 15
        }
    }
}

/// A fenced code block: monospaced, horizontally scrollable so a long line can't
/// widen the bubble, with a copy button — the one affordance the Flutter renderer
/// lacks and that a phone needs most.
struct ChatCodeBlock: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.snappy) { copied = true }
                } label: {
                    JcIcon(copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? JcTheme.success : JcTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(Color(jcHex: 0x111418), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

/// Inline markdown (bold, italics, links, `code`) the way the web UI shows it,
/// memoised per block of text — see ``ChatMarkdownCache``.
func chatInlineMarkdown(_ text: String) -> AttributedString {
    ChatMarkdownCache.inline(for: text)
}

/// A pipe table. Column widths are measured up front (the widest cell in each
/// column, capped so a wordy cell wraps), then rows are plain `HStack`s of
/// fixed-width cells: SwiftUI's `Grid` can't size rows whose cells wrap inside a
/// horizontal `ScrollView`, which is what made rows overlap. The table scrolls
/// sideways when the summed widths exceed the bubble.
struct ChatMarkdownTable: View {
    let table: MarkdownTable

    private static let cellMaxWidth: CGFloat = 220
    private static let cellMinWidth: CGFloat = 56
    private static let cellPadding: CGFloat = 10

    private var widths: [CGFloat] {
        let columns = table.header.count
        return (0..<columns).map { column in
            var widest = Self.measure(table.header[column], bold: true)
            for row in table.rows where column < row.count {
                widest = max(widest, Self.measure(row[column], bold: false))
            }
            return min(max(widest + Self.cellPadding * 2 + 2, Self.cellMinWidth), Self.cellMaxWidth)
        }
    }

    /// Single-line width of a cell's text, markdown markers stripped.
    private static func measure(_ text: String, bold: Bool) -> CGFloat {
        let plain = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let font = bold ? UIFont.systemFont(ofSize: base.pointSize, weight: .semibold) : base
        let size = (plain as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, widths: widths, header: true)
                    .background(JcTheme.surfaceAlt.opacity(0.55))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    Rectangle().fill(JcTheme.border.opacity(index == 0 ? 1 : 0.6)).frame(height: 1)
                    row(cells, widths: widths, header: false)
                }
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 1))
        }
    }

    private func row(_ cells: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                let text = column < cells.count ? cells[column] : ""
                Text(chatInlineMarkdown(text))
                    .font(header ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(header ? JcTheme.text : JcTheme.text.opacity(0.92))
                    .multilineTextAlignment(textAlignment(column))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width - Self.cellPadding * 2, alignment: frameAlignment(column))
                    .padding(.horizontal, Self.cellPadding)
                    .padding(.vertical, 7)
            }
        }
    }

    private func frameAlignment(_ column: Int) -> SwiftUI.Alignment {
        guard column < table.alignments.count else { return .topLeading }
        switch table.alignments[column] {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

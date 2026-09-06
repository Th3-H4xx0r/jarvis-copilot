import SwiftUI

/// One tool call inside an assistant turn: a spinner while it runs, a check when
/// it lands, the tool's name in monospace (without its `device_` routing prefix)
/// and one grey line of arguments-or-result. Tapping expands the full arguments
/// and result — `chat/widgets/tool_card.dart`'s card, flattened into the compact
/// row `Esp32ChatView` uses.
struct ChatToolRow: View {
    let tool: ToolInvocation
    @State private var expanded = false

    private var statusColor: Color {
        if tool.isError { return JcTheme.danger }
        return tool.done ? JcTheme.cyan : JcTheme.blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard tool.hasDetail else { return }
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .disabled(!tool.hasDetail)

            if expanded, tool.hasDetail { detail.padding(.leading, 22).padding(.top, 6) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if tool.done {
                    Image(systemName: tool.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusColor)
                        .font(.footnote)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 14, alignment: .leading)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.shortName)
                    .font(.system(.footnote, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                let line = tool.detailLine.split(separator: "\n").first.map(String.init) ?? ""
                if !line.isEmpty {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 4)
            if let seconds = tool.durationSec {
                Text(seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds))s")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if tool.hasDetail {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            let arguments = tool.args.prettyJSON
            if !arguments.isEmpty { ChatCodeBox(label: "Arguments", text: arguments) }
            let result = (tool.result ?? tool.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { ChatCodeBox(label: "Result", text: result) }
        }
    }
}

/// A labelled monospaced block — the expanded tool card's arguments and result.
/// Long output is clipped rather than left to blow the transcript's height out
/// (the Flutter card clips at the same 4 000 characters).
struct ChatCodeBox: View {
    let label: String
    let text: String

    private static let limit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(JcTheme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.count > Self.limit ? String(text.prefix(Self.limit)) + "\n…" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(jcHex: 0x0F1830), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 1))
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The "Server logs" screen, ported from `pages/more/server_logs_page.dart`.
///
/// Tails an active-profile log file (agent / errors / gateway) through
/// `GET /api/logs`, with file + tail-size + severity pickers, line wrap, 5 s
/// auto-refresh and copy-all. Lines render NEWEST FIRST, which is what the
/// Flutter page does — `ServerLogsStore.displayLines` already reverses them.
struct ServerLogsPage: View {
    @State private var store: ServerLogsStore
    @State private var toast: String?

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: ServerLogsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { ServerLogsStore() })
    }

    var body: some View {
        VStack(spacing: 0) {
            ServerLogsControls(store: store, onCopy: copyAll)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            lines
            ServerLogsFooter(store: store)
        }
        .loadErrorBanner(store.errorMessage, hasContent: !store.tail.lines.isEmpty)
        .jcScreen("Server logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    .accessibilityLabel("Reload logs")
            }
        }
        .task { if !store.hasLoaded { store.load() } }
        .onDisappear { store.onDisappear() }
        .moreToast($toast, seconds: 1.2)
    }

    @ViewBuilder
    private var lines: some View {
        if store.isLoading && !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage, store.tail.lines.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(JcTheme.danger)
                CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.displayLines.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(JcTheme.muted)
                Text(store.tail.hint.isEmpty ? "No log lines." : store.tail.hint)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ServerLogsList(store: store)
        }
    }

    private func copyAll() {
        #if canImport(UIKit)
        UIPasteboard.general.string = store.copyText
        #endif
        toast = "Logs copied"
    }
}

/// The scrolling log body. Wrap OFF puts the whole list inside a horizontal
/// scroller so long lines can be read rather than clipped.
struct ServerLogsList: View {
    let store: ServerLogsStore

    var body: some View {
        ScrollView(.vertical) {
            if store.wrapLines {
                rows.padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    rows.frame(width: 2000, alignment: .leading).padding(.horizontal, 16)
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            // Lines aren't unique (a repeated log line is common), so index is
            // the only stable identity here.
            ForEach(Array(store.displayLines.enumerated()), id: \.offset) { _, line in
                ServerLogLineRow(line: line, severity: store.severity(of: line),
                                 wrap: store.wrapLines)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One monospaced line, preceded by a thin severity rail so warnings and errors
/// stand out when scanning fast.
struct ServerLogLineRow: View {
    let line: String
    let severity: LogSeverity
    let wrap: Bool

    var body: some View {
        let tint = Color(tone: severity.tone)
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(severity == .info ? Color.clear : tint.opacity(0.7))
                .frame(width: 3, height: 13)
                .padding(.top, 2)
            Text(line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: false, vertical: wrap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

/// File / tail / severity pickers, copy, wrap + live toggles and the legend.
struct ServerLogsControls: View {
    @Bindable var store: ServerLogsStore
    let onCopy: () -> Void

    var body: some View {
        GlassCard(padding: 12, blur: false) {
            VStack(alignment: .leading, spacing: 10) {
                JcWrap(spacing: 8, runSpacing: 8) {
                    ServerLogsMenuChip(label: "File", value: store.file,
                                       options: serverLogFiles.map { ($0, $0) }) {
                        store.file = $0
                    }
                    ServerLogsMenuChip(label: "Tail", value: "\(store.tailSize)",
                                       options: ServerLogsStore.tailOptions.map { ("\($0)", "\($0)") }) {
                        store.tailSize = Int($0) ?? store.tailSize
                    }
                    ServerLogsMenuChip(label: "Show", value: store.filter.label,
                                       options: LogSeverityFilter.allCases.map { ($0.rawValue, $0.label) }) { raw in
                        if let next = LogSeverityFilter(rawValue: raw) { store.filter = next }
                    }
                    Button(action: onCopy) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc").font(.system(size: 13))
                            Text("Copy").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(JcTheme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(JcTheme.surfaceAlt,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.filteredLines.isEmpty)
                    .opacity(store.filteredLines.isEmpty ? 0.5 : 1)
                }
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                HStack(spacing: 14) {
                    compactToggle("Wrap", isOn: $store.wrapLines)
                    compactToggle("Live", isOn: $store.autoRefresh)
                    Spacer(minLength: 0)
                    legend
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 13)).foregroundStyle(JcTheme.text)
        }
        .toggleStyle(.switch)
        .tint(JcTheme.accent)
        .fixedSize()
    }

    private var legend: some View {
        HStack(spacing: 10) {
            chip(JcTheme.danger, "Error")
            chip(JcTheme.blue, "Warn")
            chip(JcTheme.muted, "Info")
        }
    }

    private func chip(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
        }
    }
}

/// A labelled dropdown chip — the Flutter `_dropdown` in SwiftUI clothes.
struct ServerLogsMenuChip: View {
    let label: String
    let value: String
    let options: [(value: String, label: String)]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) { onSelect(option.value) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold)).kerning(0.3)
                    .foregroundStyle(JcTheme.muted)
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(JcTheme.surfaceAlt,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

/// Line count, file size, mtime and the truncation note.
struct ServerLogsFooter: View {
    let store: ServerLogsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if store.autoRefresh {
                    HStack(spacing: 6) {
                        PulsingDot(color: JcTheme.success, size: 7)
                        Text("LIVE")
                            .font(.system(size: 10.5, weight: .bold)).kerning(0.6)
                            .foregroundStyle(JcTheme.success)
                    }
                }
                JcWrap(spacing: 12, runSpacing: 4) {
                    meta("list.bullet", store.countLabel)
                    if !store.tail.sizeLabel.isEmpty { meta("ruler", store.tail.sizeLabel) }
                    let mtime = store.tail.mtimeLabel()
                    meta("clock", mtime.isEmpty ? "no mtime" : "updated \(mtime)")
                }
            }
            if store.tail.truncated {
                HStack(spacing: 5) {
                    Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(JcTheme.blue)
                    Text("Truncated — showing the tail of a large file.")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
        }
    }

    private func meta(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
            Text(text).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
        }
    }
}

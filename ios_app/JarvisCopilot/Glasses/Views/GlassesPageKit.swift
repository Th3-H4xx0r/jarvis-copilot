import SwiftUI

// The glasses screens' building blocks: Settings' own pieces (`GlassQuietLabel`, `GlassGroup`,
// `GlassRow`, `LiveSettingsNote`, `.jcScreen`) arranged the way every Jarvis settings screen is.

/// A titled group of rows with an optional footnote — one Settings section.
struct GlassesSection<Content: View>: View {
    let title: String?
    var note: String? = nil
    @ViewBuilder var content: Content

    init(_ title: String?, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { GlassQuietLabel(title) }
            GlassGroup { content }
            if let note, !note.isEmpty { LiveSettingsNote(note) }
        }
    }
}

/// A sub-page: the Settings scroll, margins and title.
struct GlassesSubpage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) { content }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
        }
        .tint(JcTheme.accent)
        .jcScreen(title)
    }
}

/// A row's trailing value then the chevron, for rows that open a page.
struct GlassesRowValue: View {
    var value: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 8) {
            if let value, !value.isEmpty {
                Text(value).font(.subheadline).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
            if chevron {
                JcIcon("chevron.right", size: 14, weight: .semibold).foregroundStyle(JcTheme.muted.opacity(0.7))
            }
        }
    }
}

/// A row that opens another page.
struct GlassesLinkRow<Destination: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var last = false
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            GlassRow(symbol: symbol, title: title, subtitle: subtitle, subtitleLineLimit: 2, last: last) {
                GlassesRowValue(value: value)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A row with a switch.
struct GlassesToggleRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var last = false
    @Binding var isOn: Bool

    var body: some View {
        GlassRow(symbol: symbol, title: title, subtitle: subtitle, subtitleLineLimit: 3, last: last) {
            Toggle("", isOn: $isOn).labelsHidden().tint(JcTheme.accent)
        }
    }
}

/// A label and its value, read-only.
struct GlassesInfoRow: View {
    let symbol: String
    let title: String
    let value: String
    var last = false

    var body: some View {
        GlassRow(symbol: symbol, title: title, last: last) {
            Text(value).font(.subheadline).foregroundStyle(JcTheme.muted).lineLimit(1)
                .textSelection(.enabled)
        }
    }
}

/// A status capsule under the hero.
struct GlassesChip: View {
    let text: String
    let symbol: String
    var tint: Color = JcTheme.accent

    var body: some View {
        HStack(spacing: 6) {
            JcIcon(symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(JcTheme.text).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .jcLiquidGlass(in: Capsule())
    }
}

/// Runs one of the glasses' device skills from a screen and keeps the last outcome to show
/// under it. Shared so a sub-page and the main page say the same thing.
@MainActor
final class GlassesActions: ObservableObject {
    static let shared = GlassesActions()
    @Published private(set) var error: String?
    @Published private(set) var result: String?
    @Published private(set) var working = false

    func clear() { error = nil; result = nil }

    func run(_ name: String, _ args: [String: Any] = [:], query: Bool = false) {
        let label = name.replacingOccurrences(of: "glasses_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        error = nil; working = true
        Task {
            defer { working = false }
            do {
                if query {
                    for type in [27, 31, 32, 33, 35, 38, 28, 2, 29, 30, 34, 37, 39, 41] {
                        try await InmoSession.shared.send(InmoCommand.envelope(type: 20, field: 23, payload: InmoWireCodec.uint(1, UInt64(type))))
                    }
                }
                let response = try await InmoGo3Device.shared.invoke(name, args: args)
                result = "\(label): \(response["state"] as? String ?? "updated")"
            } catch {
                self.error = "\(label): \(error.localizedDescription)"
            }
        }
    }

    func fail(_ message: String) { error = message }
}

/// The last action's error (red) or result (muted), if any.
struct GlassesActionStatus: View {
    @ObservedObject var actions = GlassesActions.shared

    var body: some View {
        if let error = actions.error {
            Text(error).font(.system(size: 12)).foregroundStyle(JcTheme.danger)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        } else if let result = actions.result {
            Text(result).font(.system(size: 12)).foregroundStyle(JcTheme.muted).padding(.horizontal, 4)
        }
    }
}

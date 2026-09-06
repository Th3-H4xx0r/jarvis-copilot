import SwiftUI

/// The bits every Coding bottom sheet is built from — the opaque shell, the
/// field label, the labelled toggle, the host chips, the read-only row and the
/// host-aware directory typeahead. Ported from the small private widgets at the
/// bottom of `pages/coding_page.dart`.
///
/// Opaque (`JcTheme.surface`) on purpose: a translucent sheet bleeds the aurora
/// backdrop through, the recurring JARVIS-skin gotcha.

// MARK: - Shell

/// A scrolling sheet with a title, an error line and one pinned primary action.
struct CodingSheetShell<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var actionLabel: String
    var actionSymbol: String = "checkmark"
    var busy: Bool = false
    var error: String? = nil
    /// A second, ghost action on the leading side (Delete, mostly).
    var secondary: (label: String, symbol: String, action: () -> Void)? = nil
    let action: () -> Void
    @ViewBuilder var content: Content

    init(title: String,
         subtitle: String? = nil,
         actionLabel: String,
         actionSymbol: String = "checkmark",
         busy: Bool = false,
         error: String? = nil,
         secondary: (label: String, symbol: String, action: () -> Void)? = nil,
         action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.actionLabel = actionLabel
        self.actionSymbol = actionSymbol
        self.busy = busy
        self.error = error
        self.secondary = secondary
        self.action = action
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.top, 16)
                if let error, !error.isEmpty {
                    CodingInlineError(message: error).padding(.top, 16)
                }
                HStack(spacing: 12) {
                    if let secondary {
                        GlassButton(title: secondary.label, symbol: secondary.symbol,
                                    ghost: true, full: true,
                                    action: busy ? nil : secondary.action)
                    }
                    GradientButton(actionLabel, symbol: actionSymbol, busy: busy, full: true,
                                   action: busy ? nil : action)
                }
                .padding(.top, 20)
            }
            .padding(20)
        }
        .background(JcTheme.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Fields

/// The muted caption above a sheet field.
struct CodingFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled text field, single- or multi-line.
struct CodingTextField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""
    var lines: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodingFieldLabel(label)
            Group {
                if lines > 1 {
                    TextField(hint, text: $text, axis: .vertical).lineLimit(lines...)
                } else {
                    TextField(hint, text: $text)
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .jcFieldStyle()
        }
    }
}

/// A title + subtitle switch row.
struct CodingToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(JcTheme.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
        }
        .tint(JcTheme.primaryBlue)
    }
}

/// "Run on": this server, or the paired computer.
struct CodingHostPicker: View {
    @Binding var host: String

    var body: some View {
        HStack(spacing: 6) {
            chip("server", "This server")
            chip("desktop", "My computer")
        }
    }

    private func chip(_ value: String, _ label: String) -> some View {
        let selected = host == value
        return Button { host = value } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selected ? JcTheme.primaryBlue.opacity(0.20) : JcTheme.glassFill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? JcTheme.primaryBlue : JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A read-only label/value line for the session settings sheet.
struct CodingReadOnlyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(JcTheme.text)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Directory typeahead

/// A text field that offers directory suggestions for the current host/device as
/// you type, and drills in when one is tapped.
///
/// `scope` is the host or device id: changing it drops the stale list and
/// re-queries, so switching "Run on" doesn't offer the other machine's folders.
struct CodingDirSuggestField: View {
    let label: String
    @Binding var path: String
    var hint: String = ""
    /// Re-query key — the host, or the selected sync device id.
    let scope: String
    let fetch: (String) async -> [String]

    @State private var suggestions: [String] = []
    @State private var queryToken = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodingFieldLabel(label)
            TextField(hint, text: $path)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .jcFieldStyle()
            if focused && !suggestions.isEmpty {
                suggestionList
            }
        }
        .onChange(of: path) { _, _ in queryToken += 1 }
        .onChange(of: focused) { _, isFocused in
            if isFocused { queryToken += 1 } else { suggestions = [] }
        }
        .onChange(of: scope) { _, _ in
            suggestions = []
            queryToken += 1
        }
        // `.task(id:)` cancels the previous lookup, which is both the debounce
        // and the stale-response guard the Dart version hand-rolled. Only a
        // FOCUSED field queries — the suggestions are hidden otherwise, so an
        // unfocused lookup would be a wasted round trip to the device bridge.
        .task(id: queryToken) {
            guard focused else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            if Task.isCancelled { return }
            let dirs = await fetch(path)
            if !Task.isCancelled { suggestions = dirs }
        }
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(6), id: \.self) { dir in
                Button { pick(dir) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                        Text(CodingJSON.basename(dir))
                            .font(.system(size: 13)).foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(JcTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }

    private func pick(_ dir: String) {
        // The trailing separator makes the next query list the folder's children.
        path = dir.hasSuffix("/") ? dir : dir + "/"
        // Tapping the row can resign the field; without this the list vanishes
        // and the drill-down stops after one level.
        focused = true
    }
}

import SwiftUI

/// An OPAQUE scrollable sheet showing a record's full detail plus actions.
/// Ported from `widgets/detail_sheet.dart`; opaque for the same reason as
/// `FormSheet` — a translucent sheet bleeds the aurora through.
///
/// Only `content` scrolls. `footer` is pinned full-width beneath it (an
/// always-visible action bar); `actions` wrap in a row below that.
struct DetailSheet<Content: View, Footer: View, Actions: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @ViewBuilder var actions: Actions

    init(title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content()
        self.footer = footer()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .padding(.bottom, 12)
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            footer.padding(.top, 16)
            JcWrap(spacing: 10, runSpacing: 10) { actions }.padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension DetailSheet where Footer == EmptyView, Actions == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, footer: { EmptyView() }, actions: { EmptyView() })
    }
}

extension DetailSheet where Footer == EmptyView {
    init(title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.init(title: title, content: content, footer: { EmptyView() }, actions: actions)
    }
}

/// A label/value row for detail sheets. Renders nothing for a blank value, so a
/// sheet can list every field a record might have without gaps.
///
/// Named `DetailSheetRow`, not `DetailRow` as in `detail_sheet.dart`:
/// `Esp32DeviceView.swift` already has a file-private `DetailRow`, and a
/// file-scope `private` type still occupies the module namespace.
struct DetailSheetRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(JcText.small).foregroundStyle(JcTheme.muted)
                Text(value).font(JcText.body).foregroundStyle(JcTheme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        }
    }
}

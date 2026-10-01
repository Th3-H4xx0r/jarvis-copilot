import SwiftUI

/// Settings → Widget creator: Control Center buttons and switches, and the designs the
/// "Jarvis widget" shows on the Home Screen and Lock Screen.
struct WidgetCreatorPage: View {
    @ObservedObject private var store = WidgetDesignStore.shared
    @ObservedObject private var buttons = ControlButtonStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup("Control Center", footer: "Buttons and switches, each running any Jarvis action. "
                    + "Add them in Control Center as \"Jarvis button\" or \"Jarvis switch\".") {
                    NavigationLink {
                        ControlButtonsPage()
                    } label: {
                        row(symbol: "switch.2", title: "Buttons & switches",
                            detail: buttons.buttons.isEmpty ? "None yet" : "\(buttons.buttons.count)")
                    }
                    .buttonStyle(.plain)
                }

                CardGroup("Home Screen & Lock Screen", footer: "Add \"Jarvis widget\" to your Home Screen or Lock "
                    + "Screen, then touch and hold it → Edit Widget to pick one of these.") {
                    if store.designs.isEmpty {
                        Row { Text("No widgets yet").foregroundStyle(.secondary) }
                    }
                    ForEach(Array(store.designs.enumerated()), id: \.element.id) { index, info in
                        if index > 0 { RowDivider() }
                        NavigationLink {
                            destination(info)
                        } label: {
                            row(symbol: info.icon, title: info.name,
                                detail: store.draft(info.id) == nil ? "Made by Jarvis" : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                CardGroup {
                    NavigationLink {
                        WidgetTemplateGallery()
                    } label: {
                        row(symbol: "square.grid.2x2", title: "New from a template", detail: nil, accent: true)
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    NavigationLink {
                        WidgetEditor(draft: .blank(name: "My widget"), isNew: true)
                    } label: {
                        row(symbol: "plus", title: "Blank widget", detail: nil, accent: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Widget creator")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func destination(_ info: WidgetDesignInfo) -> some View {
        if let draft = store.draft(info.id) {
            WidgetEditor(draft: draft, isNew: false)
        } else {
            WidgetDesignViewer(info: info)
        }
    }

    private func row(symbol: String, title: String, detail: String?, accent: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(JcAccent.color)
                .frame(width: 26)
            Text(title).foregroundStyle(accent ? JcAccent.color : .primary)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// The starters, by area, each drawn at its smallest size with today's data.
struct WidgetTemplateGallery: View {
    @State private var data: [String: JCJSON] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(WidgetDataCatalog.areas, id: \.key) { area in
                    let templates = WidgetTemplates.all.filter { $0.area == area.key }
                    if !templates.isEmpty {
                        CardGroup(area.label) {
                            ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                                if index > 0 { RowDivider() }
                                NavigationLink {
                                    WidgetEditor(draft: template.make(ControlButtonShelf.infos()), isNew: true)
                                } label: {
                                    templateRow(template)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data = WidgetDataFile.read() }
    }

    private func templateRow(_ template: WidgetTemplate) -> some View {
        let draft = template.make(ControlButtonShelf.infos())
        let design = try? JSONDecoder().decode(JCDesign.self, from: draft.compile())
        let size = WidgetSize.allCases.first { draft.layouts[$0.rawValue] != nil } ?? .small
        return HStack(spacing: 14) {
            WidgetPreview(design: design, size: size, data: data)
                .scaleEffect(0.5, anchor: .leading)
                .frame(width: WidgetPreviewSize.points(size).width * 0.5, height: WidgetPreviewSize.points(size).height * 0.5,
                       alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name).font(.subheadline.weight(.semibold))
                Text(template.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A design Jarvis wrote by hand: shown at each size it has, with the way back into the builder.
struct WidgetDesignViewer: View {
    let info: WidgetDesignInfo
    @ObservedObject private var store = WidgetDesignStore.shared
    @State private var data: [String: JCJSON] = [:]
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let design = store.design(info.id)
        ScrollView {
            VStack(spacing: 20) {
                ForEach(WidgetSize.allCases) { size in
                    if design?.presentations.widgets[size] != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(size.label).font(.caption).foregroundStyle(.secondary)
                            WidgetPreview(design: design, size: size, data: data)
                        }
                    }
                }
                CardGroup(footer: "Jarvis made this one by hand, so it can't be edited block by block. Starting "
                    + "over keeps its name and replaces its layout when you save.") {
                    NavigationLink {
                        WidgetEditor(draft: WidgetDesignDraft(id: info.id, name: info.name, icon: info.icon, tint: nil,
                                                              layouts: [WidgetSize.small.rawValue: WidgetLayout()]),
                                     isNew: false)
                    } label: {
                        Row {
                            Text("Start over in the builder").foregroundStyle(JcAccent.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    Row {
                        Button("Delete widget", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(info.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data = WidgetDataFile.read() }
        .confirmationDialog("Delete this widget?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(info.id)
                    dismiss()
                }
            }
        }
    }
}

import SwiftUI

/// One block's settings: what it is, what it shows and how it looks.
struct WidgetBlockInspector: View {
    @Binding var block: WidgetBlock
    let onDelete: () -> Void
    @ObservedObject private var buttons = ControlButtonStore.shared
    @Environment(\.dismiss) private var dismiss

    private var isChart: Bool { block.kind == .chart || block.kind == .sparkline }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardGroup("Block") {
                    Row {
                        Picker("Type", selection: $block.kind) {
                            ForEach(WidgetBlock.Kind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                    }
                }
                if block.kind.binds {
                    CardGroup("Shows", footer: isChart ? "Charts draw a series — a week of a metric." : nil) {
                        NavigationLink {
                            WidgetDataPicker(selection: $block.source, series: isChart)
                        } label: {
                            Row {
                                HStack {
                                    Text(block.source.flatMap { WidgetDataCatalog.entry($0)?.label } ?? "Choose a value")
                                        .foregroundStyle(block.source == nil ? .secondary : .primary)
                                    Spacer()
                                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !isChart {
                            RowDivider()
                            Row { TextField("Format, e.g. {} bpm", text: optional($block.format)) }
                        }
                    }
                }
                CardGroup(block.kind == .text && block.source == nil ? "Text" : "Caption") {
                    Row { TextField(block.kind == .text ? "Words" : "Shown above it (optional)", text: optional($block.label)) }
                }
                if block.kind == .symbol || block.kind == .button {
                    CardGroup("Symbol") {
                        NavigationLink {
                            SymbolPicker(title: "Symbol", selection: block.symbol ?? "star.fill") { block.symbol = $0 }
                        } label: {
                            Row {
                                HStack {
                                    Text("Symbol")
                                    Spacer()
                                    Image(systemName: block.symbol ?? "star.fill").foregroundStyle(JcAccent.color)
                                    JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if block.kind == .button || block.kind == .toggle {
                    CardGroup(block.kind == .toggle ? "Switch" : "Button",
                              footer: "Buttons and switches come from Widget creator → Control Center.") {
                        Row {
                            Picker("Runs", selection: optionalString($block.button)) {
                                Text("Choose…").tag("")
                                ForEach(buttons.buttons.filter { $0.keepsState == (block.kind == .toggle) }) {
                                    Label($0.name, systemImage: $0.symbol).tag($0.id)
                                }
                            }
                        }
                    }
                }
                if block.kind == .model {
                    CardGroup("Device") {
                        Row {
                            Picker("Device", selection: optionalString($block.device)) {
                                ForEach(WidgetDataCatalog.wearables, id: \.key) { Text($0.name).tag($0.key) }
                            }
                        }
                    }
                }
                if isChart {
                    CardGroup("Chart") {
                        Row {
                            Picker("Style", selection: optionalString($block.chartStyle)) {
                                Text("Line").tag("line")
                                Text("Bars").tag("bar")
                                Text("Area").tag("area")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                if block.kind == .gauge || block.kind == .progress {
                    CardGroup("Full scale", footer: "The value that fills it — 100 for a score, 10000 for steps.") {
                        Row {
                            TextField("100", value: $block.max, format: .number)
                                .keyboardType(.decimalPad)
                        }
                    }
                }
                if block.kind != .spacer && block.kind != .divider {
                    CardGroup("Look") {
                        Row {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Colour")
                                WidgetColorSwatches(selection: $block.color)
                            }
                        }
                        RowDivider()
                        Row {
                            let isHeight = block.kind == .model || block.kind == .chart
                            Stepper(value: Binding(get: { block.size ?? (isHeight ? 80 : 15) }, set: { block.size = $0 }),
                                    in: isHeight ? 30...240 : 8...60, step: isHeight ? 10 : 1) {
                                Text("\(isHeight ? "Height" : "Size") \(Int(block.size ?? (isHeight ? 80 : 15)))")
                            }
                        }
                    }
                }
                CardGroup {
                    Row {
                        Button("Remove block", role: .destructive, action: onDelete)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(block.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalString(_ binding: Binding<String?>) -> Binding<String> { optional(binding) }
}

/// Every value a widget can show, by area, with what it reads right now.
struct WidgetDataPicker: View {
    @Binding var selection: String?
    let series: Bool
    @State private var data: [String: JCJSON] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(WidgetDataCatalog.areas, id: \.key) { area in
                    let entries = WidgetDataCatalog.entries(area: area.key).filter { ($0.kind == .series) == series }
                    if !entries.isEmpty {
                        CardGroup(area.label) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { RowDivider() }
                                Button {
                                    selection = entry.key
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.label).font(.subheadline)
                                            Text(now(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if selection == entry.key { Image(systemName: "checkmark").foregroundStyle(JcAccent.color) }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
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
        .navigationTitle(series ? "Series" : "Value")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { data = WidgetDataFile.read() }
    }

    private func now(_ entry: WidgetDataCatalog.Entry) -> String {
        guard let value = data[entry.key] else { return "Nothing yet" }
        switch value {
        case .array(let items): return "\(items.count) points"
        case .bool(let b): return b ? "Yes" : "No"
        default: return [value.asString, entry.unit].compactMap { $0 }.joined(separator: " ")
        }
    }
}

import SwiftUI

/// Editing a dashboard on the phone: rename it, reorder its widgets (hold and drag), add from
/// the library (kinds × readings from the catalog), change a widget's settings, delete widgets
/// or the whole dashboard. Save puts the one-column order back on the 12-column grid and
/// writes it with its revision; if someone saved first, the page reloads and says so.
struct PcDashboardEditor: View {
    let model: PcStatsModel
    let original: PcDashboard

    @State private var draft: PcDashboard
    @State private var errors: [String] = []
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var showLibrary = false
    @Environment(\.dismiss) private var dismiss

    init(model: PcStatsModel, original: PcDashboard) {
        self.model = model
        self.original = original
        _draft = State(initialValue: PcDashboard(id: original.id, name: original.name, auto: original.auto,
                                                 widgets: PcLayout.reflow(original.widgets), rev: original.rev))
    }

    private var changed: Bool {
        draft.name != original.name || draft.auto != original.auto
            || draft.widgets != PcLayout.reflow(original.widgets)
    }

    var body: some View {
        NavigationStack {
            List {
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { e in
                            Label { Text(e) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                .font(.footnote)
                                .foregroundStyle(JcTheme.danger)
                        }
                    }
                    .listRowBackground(JcTheme.surface)
                }
                Section {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                    Toggle("Show on the PC while a game runs", isOn: Binding(
                        get: { draft.auto == "game" }, set: { draft.auto = $0 ? "game" : nil }))
                        .tint(JcAccent.control)
                } header: {
                    Text("Dashboard")
                } footer: {
                    if let other = model.dashboards.first(where: { $0.auto == "game" && $0.id != draft.id }), draft.auto == "game" {
                        Text("Only one dashboard can be the game one: \(other.name) stops being it.")
                    }
                }
                .listRowBackground(JcTheme.surface)

                Section {
                    ForEach(draft.widgets) { w in
                        NavigationLink(value: w.id) { widgetRow(w) }
                    }
                    .onMove { draft.widgets.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { draft.widgets.remove(atOffsets: $0) }
                    Button { showLibrary = true } label: {
                        Label("Add widget", jcIcon: "plus")
                            .foregroundStyle(JcTheme.accent)
                    }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Hold and drag to reorder, swipe left to delete. The PC and web keep each widget's size; a new order is laid out on their grid in the same order.")
                }
                .listRowBackground(JcTheme.surface)

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete dashboard", jcIcon: "trash")
                    }
                    .disabled(model.dashboards.count <= 1)
                } footer: {
                    if model.dashboards.count <= 1 { Text("The last dashboard can't be deleted.") }
                }
                .listRowBackground(JcTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Edit dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let binding = widgetBinding(id) {
                    PcWidgetSettings(widget: binding, catalog: model.catalog, extraKeys: model.dynamicKeys) {
                        draft.widgets.removeAll { $0.id == id }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        JcLoader(size: 18)
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!changed || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showLibrary) {
                PcWidgetLibrary(catalog: model.catalog, extraKeys: model.dynamicKeys,
                                taken: Set(draft.widgets.map(\.id))) { draft.widgets.append($0) }
            }
            .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete dashboard", role: .destructive) { deleteBoard() }
            } message: {
                Text("It goes from your PC, the web and this phone.")
            }
        }
        .interactiveDismissDisabled(changed)
    }

    private func widgetRow(_ w: PcWidget) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: w.kind.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title(model.catalog)).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                Text(PcEditorCopy.subtitle(w, catalog: model.catalog))
                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
        }
    }

    private func widgetBinding(_ id: String) -> Binding<PcWidget>? {
        guard let w = draft.widgets.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { draft.widgets.first { $0.id == id } ?? w },
            set: { new in if let i = draft.widgets.firstIndex(where: { $0.id == id }) { draft.widgets[i] = new } })
    }

    private func save() {
        var board = draft
        board.name = board.name.trimmingCharacters(in: .whitespacesAndNewlines)
        board.widgets = PcLayout.commit(original: original.widgets, edited: draft.widgets)
        board.rev = original.rev
        saving = true
        errors = []
        Task {
            let outcome = await model.save(board)
            saving = false
            switch outcome {
            case .saved, .conflict: dismiss()
            case .invalid(let e): errors = e
            case .failed(let why): errors = [why]
            }
        }
    }

    private func deleteBoard() {
        saving = true
        Task {
            if let err = await model.deleteDashboard(original.id) {
                errors = [err]
                saving = false
            } else {
                dismiss()
            }
        }
    }
}

enum PcEditorCopy {
    /// "Hero · GPU load", "Bars · 4 readings", "Text".
    static func subtitle(_ w: PcWidget, catalog: PcCatalog) -> String {
        guard w.kind.takesReadings, let first = w.primary else { return w.kind.title }
        if w.readings.count > 1 { return "\(w.kind.title) · \(w.readings.count) readings" }
        return "\(w.kind.title) · \(catalog.info(first)?.label ?? first)"
    }

    /// A new widget of a kind on a reading, with the defaults that kind looks right with.
    static func makeWidget(kind: PcWidgetKind, reading: String?, catalog: PcCatalog, taken: Set<String>) -> PcWidget {
        let size = kind.defaultSize
        var style = PcWidgetStyle()
        switch kind {
        case .hero: style.chart = .area
        case .chart, .sparkline: style.chart = .line
        case .text: style.label = "Heading"
        default: break
        }
        if kind == .hero, let r = reading, let info = catalog.info(r) { style.label = info.label }
        return PcWidget(id: PcLayout.newWidgetID(kind: kind, reading: reading, taken: taken), kind: kind,
                        w: size.w, h: size.h, readings: reading.map { [$0] } ?? [], style: style)
    }
}

// MARK: - Library

/// "+": pick a kind, then (for kinds that show a reading) the reading.
struct PcWidgetLibrary: View {
    let catalog: PcCatalog
    let extraKeys: [String]
    let taken: Set<String>
    let add: (PcWidget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(catalog.kinds) { kind in
                        if kind.takesReadings {
                            NavigationLink(value: kind) { kindRow(kind) }
                        } else {
                            Button {
                                add(PcEditorCopy.makeWidget(kind: kind, reading: nil, catalog: catalog, taken: taken))
                                dismiss()
                            } label: { kindRow(kind) }
                        }
                    }
                } footer: {
                    Text("Every widget can be restyled after it's added.")
                }
                .listRowBackground(JcTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Add widget")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PcWidgetKind.self) { kind in
                PcReadingPicker(catalog: catalog, extraKeys: extraKeys, selected: [], title: kind.title) { key in
                    add(PcEditorCopy.makeWidget(kind: kind, reading: key, catalog: catalog, taken: taken))
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func kindRow(_ kind: PcWidgetKind) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: kind.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                Text(kind.blurb).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

/// The catalog's readings by group, plus this PC's own fans and temperatures.
struct PcReadingPicker: View {
    let catalog: PcCatalog
    let extraKeys: [String]
    let selected: [String]
    var title = "Reading"
    let pick: (String) -> Void

    var body: some View {
        let groups = catalog.grouped(extraKeys: extraKeys)
        List {
            if groups.isEmpty {
                Text("The reading list didn't load. Go back and try again.")
                    .foregroundStyle(JcTheme.muted)
                    .listRowBackground(JcTheme.surface)
            }
            ForEach(groups) { g in
                Section(PcCatalog.groupTitle(g.group)) {
                    ForEach(g.readings, id: \.key) { r in
                        Button { pick(r.key) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(r.label).font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                                        if r.estimated { PcEstimatedBadge() }
                                    }
                                    Text(r.unit.isEmpty ? r.key : "\(r.key) · \(r.unit)")
                                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                                }
                                Spacer()
                                if selected.contains(r.key) {
                                    Image(systemName: "checkmark").foregroundStyle(JcTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(selected.contains(r.key))
                    }
                }
                .listRowBackground(JcTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Widget settings

/// One widget's settings: label, readings, meta row, chart, colour, warn/crit, window,
/// decimals; and delete.
struct PcWidgetSettings: View {
    @Binding var widget: PcWidget
    let catalog: PcCatalog
    let extraKeys: [String]
    let delete: () -> Void

    @State private var warnText = ""
    @State private var critText = ""
    @State private var picking: PickTarget?
    @Environment(\.dismiss) private var dismiss

    private enum PickTarget: Hashable { case reading, meta }

    var body: some View {
        Form {
            Section("Label") {
                TextField(widget.kind == .text ? "Heading" : (widget.primary.flatMap { catalog.info($0)?.label } ?? widget.kind.title),
                          text: Binding(get: { widget.style.label ?? "" },
                                        set: { widget.style.label = $0.isEmpty ? nil : $0 }))
            }
            .listRowBackground(JcTheme.surface)

            if widget.kind.takesReadings {
                Section {
                    ForEach(widget.readings, id: \.self) { key in
                        readingRow(key)
                    }
                    .onDelete { widget.readings.remove(atOffsets: $0) }
                    .onMove { widget.readings.move(fromOffsets: $0, toOffset: $1) }
                    if widget.kind.multiReading || widget.readings.isEmpty {
                        Button { picking = .reading } label: { Label("Add reading", jcIcon: "plus").foregroundStyle(JcTheme.accent) }
                    } else {
                        Button { picking = .reading } label: { Label("Change reading", jcIcon: "arrow.left.arrow.right").foregroundStyle(JcTheme.accent) }
                    }
                } header: {
                    Text(widget.kind.multiReading ? "Readings" : "Reading")
                }
                .listRowBackground(JcTheme.surface)
            }

            if widget.kind.hasMeta {
                Section {
                    ForEach(widget.style.meta, id: \.self) { key in readingRow(key) }
                        .onDelete { widget.style.meta.remove(atOffsets: $0) }
                        .onMove { widget.style.meta.move(fromOffsets: $0, toOffset: $1) }
                    Button { picking = .meta } label: { Label("Add to meta row", jcIcon: "plus").foregroundStyle(JcTheme.accent) }
                } header: {
                    Text("Meta row")
                } footer: {
                    Text(widget.kind == .bars ? "The first one is shown big above the bars." : "Small numbers under the big one.")
                }
                .listRowBackground(JcTheme.surface)
            }

            if widget.kind.hasChart {
                Section("Chart") {
                    Picker("Chart", selection: Binding(
                        get: { widget.style.chart ?? (widget.kind == .hero ? .area : .line) },
                        set: { widget.style.chart = $0 })) {
                        ForEach(PcChartType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Live window", selection: Binding(
                        get: { widget.style.window ?? 0 }, set: { widget.style.window = $0 == 0 ? nil : $0 })) {
                        Text("Default (\(PcStatsCopy.window(PcLayout.liveWindow)))").tag(0)
                        ForEach(PcStatsCopy.windows, id: \.self) { Text(PcStatsCopy.window($0)).tag($0) }
                    }
                }
                .listRowBackground(JcTheme.surface)
            }

            if widget.kind != .text {
                Section("Colour") {
                    colourGrid
                }
                .listRowBackground(JcTheme.surface)
            }

            if widget.kind.takesReadings {
                Section {
                    thresholdField("Amber at", text: $warnText) { widget.style.warn = $0 }
                    thresholdField("Red at", text: $critText) { widget.style.crit = $0 }
                    Picker("Decimals", selection: Binding(
                        get: { widget.style.decimals ?? -1 }, set: { widget.style.decimals = $0 < 0 ? nil : $0 })) {
                        Text("Auto").tag(-1)
                        ForEach(0...3, id: \.self) { Text("\($0)").tag($0) }
                    }
                } header: {
                    Text("Numbers")
                } footer: {
                    Text("A value at or over a limit turns amber or red. Leave empty for none.")
                }
                .listRowBackground(JcTheme.surface)
            }

            Section {
                Button(role: .destructive) {
                    delete()
                    dismiss()
                } label: { Label("Delete widget", jcIcon: "trash") }
            }
            .listRowBackground(JcTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(widget.title(catalog))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            warnText = widget.style.warn.map { PcFormat.number($0, unit: "", decimals: $0.rounded() == $0 ? 0 : 1) } ?? ""
            critText = widget.style.crit.map { PcFormat.number($0, unit: "", decimals: $0.rounded() == $0 ? 0 : 1) } ?? ""
        }
        .navigationDestination(item: $picking) { target in
            PcReadingPicker(catalog: catalog, extraKeys: extraKeys,
                            selected: target == .meta ? widget.style.meta : widget.readings,
                            title: target == .meta ? "Meta row" : "Reading") { key in
                if target == .meta {
                    widget.style.meta.append(key)
                } else if widget.kind.multiReading {
                    widget.readings.append(key)
                } else {
                    widget.readings = [key]
                }
                picking = nil
            }
        }
    }

    private func readingRow(_ key: String) -> some View {
        HStack {
            Text(catalog.info(key)?.label ?? key).foregroundStyle(JcTheme.text)
            Spacer()
            Text(catalog.info(key)?.unit ?? "").foregroundStyle(JcTheme.muted)
        }
    }

    private var colourGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
            swatch(nil)
            ForEach(PcLook.palette, id: \.self) { swatch($0) }
        }
        .padding(.vertical, 6)
    }

    private func swatch(_ hex: String?) -> some View {
        let chosen = widget.style.color?.uppercased() == hex?.uppercased()
        return Button { widget.style.color = hex } label: {
            ZStack {
                if let c = PcLook.color(hex) {
                    Circle().fill(c)
                } else {
                    Circle().fill(LinearGradient(colors: [PcLook.barLo, PcLook.barHi], startPoint: .bottomLeading, endPoint: .topTrailing))
                }
                if chosen {
                    Circle().strokeBorder(JcTheme.bg, lineWidth: 2.5).padding(2.5)
                    Circle().strokeBorder(JcTheme.text, lineWidth: 2)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? "Default colour" : "Colour \(hex!)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func thresholdField(_ title: String, text: Binding<String>, set: @escaping (Double?) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("None", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 120)
                .onChange(of: text.wrappedValue) { _, new in
                    let cleaned = new.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    set(cleaned.isEmpty ? nil : Double(cleaned))
                }
        }
    }
}

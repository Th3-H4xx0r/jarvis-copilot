import SwiftUI

/// The harness canvas: drag steps around, wire one step's output dot to
/// another, tap a step for its settings, tap a wire's label to change or drop
/// it. Pinch to zoom, drag empty space to pan. The server validates on Save and
/// its problems are drawn on the steps they belong to.
struct HarnessEditorView: View {
    static let nodeSize = CGSize(width: 156, height: 60)

    @State private var harness: AgentHarness
    @State private var problems: [HarnessProblem]
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var wiringFrom: String?
    @State private var editingNodeID: String?
    @State private var editingEdge: Int?
    @State private var saving = false
    @State private var banner: String?
    private var store: HarnessStore { HarnessStore.shared }

    init(harness: AgentHarness) {
        _harness = State(initialValue: harness)
        _problems = State(initialValue: harness.problems ?? [])
    }

    private var readOnly: Bool { harness.isBuiltin }

    private var canvasSize: CGSize {
        let maxX = harness.nodes.map(\.x).max() ?? 0
        let maxY = harness.nodes.map(\.y).max() ?? 0
        return CGSize(width: max(900, maxX + 500), height: max(1100, maxY + 500))
    }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            JcTheme.bg.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { v in
                        pan = CGSize(width: basePan.width + v.translation.width,
                                     height: basePan.height + v.translation.height)
                    }
                    .onEnded { _ in basePan = pan })
                .onTapGesture { wiringFrom = nil }
            canvas
                .scaleEffect(scale, anchor: .topLeading)
                .offset(pan)
        }
        // The canvas is bigger than the screen. A FIXED frame of the screen's own
        // size pins it top-left; a flexible one grows to the canvas and is then
        // centred, starting the left half of the graph off-screen.
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in scale = min(2.5, max(0.4, baseScale * v.magnification)) }
            .onEnded { _ in baseScale = scale })
        .clipped()
        .overlay(alignment: .top) { bannerView }
        .overlay(alignment: .bottom) { hint }
        .jcScreen()
        .navigationTitle(harness.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: Binding(get: { editingNodeID.map(NodeRef.init) }, set: { editingNodeID = $0?.id })) { ref in
            HarnessNodeSheet(harness: $harness, nodeID: ref.id, readOnly: readOnly,
                             problems: problems.filter { $0.node == ref.id })
        }
        .confirmationDialog("Wire", isPresented: Binding(get: { editingEdge != nil },
                                                          set: { if !$0 { editingEdge = nil } }),
                            titleVisibility: .visible) { edgeActions }
    }

    // MARK: Canvas

    private var canvas: some View {
        let w = Self.nodeSize.width, h = Self.nodeSize.height
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for edge in harness.edges {
                    guard let a = harness.node(edge.from), let b = harness.node(edge.to) else { continue }
                    // Steps flow top to bottom: out of a step's bottom, into the next one's top.
                    // The upward wire of a pair (Answer --hands--> Computer --stuck--> Answer)
                    // runs top to bottom beside its partner instead of looping behind both steps.
                    let up = b.y + h <= a.y && harness.edges.contains { $0.from == edge.to && $0.to == edge.from }
                    let start = up ? CGPoint(x: a.x + w / 2 + 14, y: a.y) : CGPoint(x: a.x + w / 2, y: a.y + h)
                    let end = up ? CGPoint(x: b.x + w / 2 + 14, y: b.y + h) : CGPoint(x: b.x + w / 2, y: b.y)
                    let dy = max(40, abs(end.y - start.y) / 2) * (up ? -1 : 1)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + dy),
                                  control2: CGPoint(x: end.x, y: end.y - dy))
                    ctx.stroke(path, with: .color(JcTheme.accent.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: edge.isDashed ? [5, 4] : []))
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)

            ForEach(Array(harness.edges.enumerated()), id: \.offset) { index, edge in
                if let a = harness.node(edge.from), let b = harness.node(edge.to) {
                    // A wire and its reverse (Answer --hands--> Computer --stuck--> Answer)
                    // share a midpoint; their labels step apart so both stay tappable.
                    let twin = harness.edges.contains { $0.from == edge.to && $0.to == edge.from }
                    let nudge: CGFloat = twin ? (edge.from < edge.to ? -12 : 12) : 0
                    Button { if !readOnly { editingEdge = index } } label: {
                        Text(edge.when == "always" ? "•" : HarnessGraph.wireTitle(edge.when))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(edgeHasProblem(index) ? JcTheme.danger : JcTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(JcTheme.surface))
                    }
                    .buttonStyle(.plain)
                    .position(x: (a.x + b.x) / 2 + w / 2, y: (a.y + h + b.y) / 2 + nudge)
                }
            }

            ForEach(harness.nodes) { node in
                HarnessNodeCard(node: node,
                                problems: problems.filter { $0.node == node.id },
                                isWireSource: wiringFrom == node.id,
                                wiring: wiringFrom != nil,
                                canWireOut: !readOnly && node.type != .review,
                                onTap: { tap(node) },
                                onOutput: { wiringFrom = (wiringFrom == node.id) ? nil : node.id })
                    .position(x: node.x + w / 2, y: node.y + h / 2)
                    .gesture(readOnly ? nil : drag(node))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func drag(_ node: HarnessNode) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let start = dragStart[node.id] ?? CGPoint(x: node.x, y: node.y)
                dragStart[node.id] = start
                guard let i = harness.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                harness.nodes[i].x = max(0, (start.x + v.translation.width / scale).rounded())
                harness.nodes[i].y = max(0, (start.y + v.translation.height / scale).rounded())
            }
            .onEnded { _ in dragStart[node.id] = nil }
    }

    private func tap(_ node: HarnessNode) {
        if let from = wiringFrom {
            if from != node.id {
                if !HarnessGraph.canWire(harness, from: from, to: node.id) {
                    banner = "A Background step only wires to a Computer step."
                } else if !HarnessGraph.wire(&harness, from: from, to: node.id) {
                    banner = "Those two are already wired."
                }
            }
            wiringFrom = nil
            return
        }
        editingNodeID = node.id
    }

    private func edgeHasProblem(_ index: Int) -> Bool { problems.contains { $0.edge == index } }

    // MARK: Wire actions

    @ViewBuilder private var edgeActions: some View {
        if let index = editingEdge, harness.edges.indices.contains(index) {
            ForEach(HarnessGraph.wireChoices(harness, edge: index), id: \.self) { when in
                Button(HarnessGraph.wireTitle(when)) { setWhen(when, edge: index); editingEdge = nil }
            }
            Button("Remove wire", role: .destructive) {
                HarnessGraph.disconnect(&harness, index: index)
                editingEdge = nil
            }
        }
    }

    /// A Route wire's label goes through ``HarnessGraph/relabelWire`` so the
    /// Route's labels and wires never drift apart (a router could never pick it).
    private func setWhen(_ when: String, edge index: Int) {
        guard when.hasPrefix("label:"), harness.edges[index].when.hasPrefix("label:"),
              harness.node(harness.edges[index].from)?.type == .route else {
            harness.edges[index].when = when
            return
        }
        if !HarnessGraph.relabelWire(&harness, edge: index, to: String(when.dropFirst("label:".count))) {
            banner = "Another wire already has that label."
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if readOnly {
            ToolbarItem(placement: .topBarTrailing) {
                Text("Built-in").font(JcText.small).foregroundStyle(JcTheme.muted)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([HarnessNodeType.answer, .route, .background, .review, .computer], id: \.self) { type in
                        Button(type.label, jcIcon: type.symbol) {
                            let point = CGPoint(x: (-pan.width + 60) / scale, y: (-pan.height + 140) / scale)
                            editingNodeID = HarnessGraph.addNode(&harness, type: type, at: point)
                        }
                    }
                } label: { JcIcon("plus").foregroundStyle(JcTheme.accent) }
                .accessibilityLabel("Add step")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving)
            }
        }
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(JcText.small)
                .foregroundStyle(JcTheme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(JcTheme.surfaceAlt))
                .padding(.top, 8)
                .onTapGesture { self.banner = nil }
        }
    }

    @ViewBuilder private var hint: some View {
        if wiringFrom != nil {
            Text("Tap the step to wire to")
                .font(JcText.small).foregroundStyle(JcTheme.accent)
                .padding(10).background(Capsule().fill(JcTheme.surface))
                .padding(.bottom, 16)
        } else if readOnly {
            Button("Duplicate to edit") { duplicateForEditing() }
                .buttonStyle(.jcGlass)
                .padding(.bottom, 16)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let found = await store.save(harness)
        problems = found
        banner = found.isEmpty ? "Saved." : (found.first { $0.node == nil && $0.edge == nil }?.message
                                            ?? "Fix the marked steps, then save again.")
    }

    private func duplicateForEditing() {
        var id = "\(harness.id)-copy"
        var n = 2
        while store.harness(id) != nil { id = "\(harness.id)-copy-\(n)"; n += 1 }
        harness = HarnessGraph.duplicate(harness, id: id, name: "\(harness.name) copy")
        problems = []
        banner = "Editing a copy — Save to keep it."
    }
}

private struct NodeRef: Identifiable { let id: String }

/// One step on the canvas: its type, name and model, an output dot to start a wire.
struct HarnessNodeCard: View {
    let node: HarnessNode
    let problems: [HarnessProblem]
    let isWireSource: Bool
    let wiring: Bool
    let canWireOut: Bool
    let onTap: () -> Void
    let onOutput: () -> Void

    var body: some View {
        let size = HarnessEditorView.nodeSize
        VStack(alignment: .leading, spacing: 2) {
                Text(node.type.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                Text(node.label ?? node.id)
                    .font(JcText.small).foregroundStyle(JcTheme.text).lineLimit(1)
                if let model = node.model, !model.isEmpty {
                    Text(model == "@session" ? "chat's model" : HarnessFormat.shortModel(model))
                        .font(.system(size: 10)).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .background(RoundedRectangle(cornerRadius: 12).fill(JcTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(!problems.isEmpty ? JcTheme.danger : (isWireSource ? JcTheme.accent : JcTheme.border),
                    lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if !problems.isEmpty {
                JcIcon("exclamationmark.circle.fill").foregroundStyle(JcTheme.danger).offset(x: 6, y: -6)
            }
        }
        .overlay(alignment: .top) {
            if node.type != .message {
                Circle().fill(JcTheme.accent.opacity(wiring ? 1 : 0.5))
                    .frame(width: 10, height: 10)
                    .offset(y: -5)
            }
        }
        .overlay(alignment: .bottom) {
            if canWireOut {
                Button(action: onOutput) {
                    Circle().fill(JcTheme.accent).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(JcTheme.text, lineWidth: isWireSource ? 2 : 0))
                        .padding(8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(y: 15)
                .accessibilityLabel("Wire from \(node.label ?? node.id)")
            }
        }
    }
}

/// A step's settings: model, tools, delivery, route rules, a Computer step's
/// models and step budget, instructions.
struct HarnessNodeSheet: View {
    @Binding var harness: AgentHarness
    let nodeID: String
    let readOnly: Bool
    let problems: [HarnessProblem]

    @Environment(\.dismiss) private var dismiss
    @State private var pickingModel: ModelField?
    @State private var catalog: ModelCatalog?

    private enum ModelField: String, Identifiable { case model, fallback; var id: String { rawValue } }

    private var index: Int? { harness.nodes.firstIndex { $0.id == nodeID } }

    var body: some View {
        NavigationStack {
            Form {
                if let i = index { fields(i) }
                ForEach(problems, id: \.self) { p in
                    Text(p.message).font(JcText.small).foregroundStyle(JcTheme.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .jcScreen()
            .disabled(readOnly)
            .navigationTitle(index.map { harness.nodes[$0].type.label } ?? "Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if !readOnly, let i = index, harness.nodes[i].type != .message {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete", role: .destructive) {
                            HarnessGraph.removeNode(&harness, id: nodeID)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $pickingModel) { field in modelPicker(field) }
    }

    private var isComputer: Bool { index.map { harness.nodes[$0].type == .computer } == true }

    @ViewBuilder private func modelPicker(_ field: ModelField) -> some View {
        if isComputer {
            // Decision model: decision models only, "Automatic" = the first one
            // available. Fallback: chat models only, empty = the calling node's model.
            let decision = field == .model
            let list = decision ? catalog?.decisionOnly() : catalog
            let ref = index.flatMap { decision ? harness.nodes[$0].model : harness.nodes[$0].fallbackModel }
            CatalogModelPickerSheet(title: decision ? "Decision model" : "Fallback model",
                                    catalog: list,
                                    selectedID: catalogID(ref, in: list),
                                    autoTitle: decision ? "Automatic" : "Same as the main model",
                                    autoSubtitle: decision ? "The first decision model available."
                                                           : "The model that handed this step the Mac.",
                                    load: { catalog = try? await ModelsAPI().list() },
                                    select: { picked in setModel(field, picked) })
        } else {
            let router = isRouterPick(field)
            CatalogModelPickerSheet(title: router ? "Router model" : field == .model ? "Step model" : "Fallback model",
                                    catalog: router ? catalog?.forRouter() : catalog,
                                    selectedID: nil,
                                    autoSubtitle: "The chat's own model.",
                                    showsAuto: !router,
                                    load: { catalog = try? await ModelsAPI().list() },
                                    select: { picked in setModel(field, picked) })
        }
    }

    /// The catalog id a stored ref names (refs carry `@provider:`, catalog ids may not).
    private func catalogID(_ ref: String?, in list: ModelCatalog?) -> String? {
        guard let ref, !ref.isEmpty else { return nil }
        return list?.models.first { Self.ref(for: $0) == ref }?.id ?? ref
    }

    private static func ref(for m: ChatModel) -> String {
        m.id.hasPrefix("@") || m.providerID.isEmpty ? m.id : "@\(m.providerID):\(m.id)"
    }

    /// A Route's model is its router: decision models lead the list, and there is
    /// no "Auto" — that stores `@session`, the chat's own model, not a router.
    private func isRouterPick(_ field: ModelField) -> Bool {
        field == .model && index.map { harness.nodes[$0].type == .route } == true
    }

    @ViewBuilder private func fields(_ i: Int) -> some View {
        let type = harness.nodes[i].type
        Section("Name") {
            TextField("Label", text: Binding(get: { harness.nodes[i].label ?? "" },
                                            set: { harness.nodes[i].label = $0.isEmpty ? nil : $0 }))
        }
        if type == .computer { computerFields(i) }
        if type == .answer || type == .background || type == .review || (type == .route && harness.nodes[i].by == "model") {
            Section(type == .route ? "Router model" : "Model") {
                Button { pickingModel = .model } label: {
                    HStack {
                        Text(modelText(harness.nodes[i].model)).foregroundStyle(JcTheme.text)
                        Spacer()
                        JcIcon("chevron.right").foregroundStyle(JcTheme.muted)
                    }
                }
            }
        }
        if type == .answer || type == .background {
            Section("Tools") {
                Picker("Tools", selection: Binding(
                    get: { if case .preset(let p) = harness.nodes[i].tools { return p }; return "lean" },
                    set: { harness.nodes[i].tools = .preset($0) })) {
                    Text("Lean").tag("lean")
                    Text("All").tag("all")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
            }
        }
        if type == .answer {
            Section("If it fails") {
                Button { pickingModel = .fallback } label: {
                    HStack {
                        Text(harness.nodes[i].fallbackModel.map(modelText) ?? "No fallback")
                            .foregroundStyle(JcTheme.text)
                        Spacer()
                        JcIcon("chevron.right").foregroundStyle(JcTheme.muted)
                    }
                }
            }
        }
        if type == .background {
            Section("Result") {
                Picker("Delivery", selection: Binding(get: { harness.nodes[i].deliver ?? "speak_or_notify" },
                                                      set: { harness.nodes[i].deliver = $0 })) {
                    Text("Speak if Voice is open, else notify").tag("speak_or_notify")
                    Text("Post in the chat").tag("post")
                    Text("Notify").tag("notify")
                }
            }
        }
        if type == .review {
            Section("Result") {
                Picker("Delivery", selection: Binding(get: { harness.nodes[i].deliver ?? "post_if_changed" },
                                                      set: { harness.nodes[i].deliver = $0 })) {
                    Text("Post only a correction").tag("post_if_changed")
                    Text("Always post").tag("post")
                }
            }
        }
        if type == .route { routeFields(i) }
        if type != .message && (type != .route || harness.nodes[i].by == "model") {
            Section(type == .route ? "Question for the router" : "Extra instructions") {
                TextField(type == .route ? "Which route should handle the user's message?" : "Optional",
                          text: Binding(get: { harness.nodes[i].instructions ?? "" },
                                        set: { harness.nodes[i].instructions = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
                    .lineLimit(2...6)
            }
        }
    }

    @ViewBuilder private func computerFields(_ i: Int) -> some View {
        Section {
            pickerRow(harness.nodes[i].model.flatMap { $0.isEmpty ? nil : HarnessFormat.shortModel($0) }
                      ?? "Automatic") { pickingModel = .model }
        } header: {
            Text("Decision model")
        } footer: {
            Text("Drives your Mac: the decision model picks each click; the fallback model takes steps it's unsure about.")
        }
        Section("Fallback model") {
            pickerRow(harness.nodes[i].fallbackModel.flatMap { $0.isEmpty ? nil : HarnessFormat.shortModel($0) }
                      ?? "Same as the main model") { pickingModel = .fallback }
        }
        Section {
            let steps = harness.nodes[i].maxSteps ?? 30
            Stepper("Max steps: \(steps)", value: Binding(get: { steps },
                                                          set: { harness.nodes[i].maxSteps = $0 }),
                    in: 1...60)
        } footer: {
            Text("A Hands wire gives an Answer or Background step the Mac. A When stuck wire to an Answer step finishes what this can't.")
        }
    }

    private func pickerRow(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).foregroundStyle(JcTheme.text)
                Spacer()
                JcIcon("chevron.right").foregroundStyle(JcTheme.muted)
            }
        }
    }

    @ViewBuilder private func routeFields(_ i: Int) -> some View {
        Section("Pick by") {
            Picker("Pick by", selection: Binding(get: { harness.nodes[i].by ?? "rules" },
                                                 set: { harness.nodes[i].by = $0 })) {
                Text("Rules").tag("rules")
                Text("A model").tag("model")
            }
            .pickerStyle(.segmented)
        }
        let labels = harness.nodes[i].labels ?? []
        Section {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                HarnessLabelRow(name: label,
                                note: Binding(get: { harness.node(nodeID)?.labelDescriptions?[label] ?? "" },
                                              set: { HarnessGraph.describeLabel(&harness, node: nodeID,
                                                                                label: label, as: $0) }),
                                rename: { HarnessGraph.renameLabel(&harness, node: nodeID, from: label, to: $0) })
            }
            .onDelete { HarnessGraph.removeLabels(&harness, node: nodeID, at: $0) }
            Button("Add label") { HarnessGraph.addLabel(&harness, node: nodeID) }
        } header: {
            Text("Labels")
        } footer: {
            if harness.nodes[i].by == "model" {
                Text(labels.isEmpty ? "No labels yet — add one, or draw a wire out of this Route."
                                    : "The router picks one. Say what each means so it picks well.")
            }
        }
        if harness.nodes[i].by != "model" {
            Section("Rules") {
                ForEach(Array((harness.nodes[i].rules ?? []).enumerated()), id: \.offset) { r, rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Match", selection: Binding(get: { rule.match },
                                                           set: { harness.nodes[i].rules?[r].match = $0 })) {
                            Text("Keywords").tag("keywords")
                            Text("Regex").tag("regex")
                            Text("Surface").tag("surface")
                            Text("Has attachment").tag("has_attachment")
                        }
                        if rule.match != "has_attachment" {
                            TextField("Value", text: Binding(
                                get: { rule.value?.text ?? "" },
                                set: { harness.nodes[i].rules?[r].value = .string($0) }))
                        }
                        TextField("Label", text: Binding(get: { rule.label },
                                                         set: { harness.nodes[i].rules?[r].label = $0 }))
                    }
                }
                .onDelete { harness.nodes[i].rules?.remove(atOffsets: $0) }
                Button("Add rule") {
                    harness.nodes[i].rules = (harness.nodes[i].rules ?? [])
                        + [HarnessRule(match: "keywords", value: .string(""),
                                       label: harness.nodes[i].labels?.first ?? "deep")]
                }
            }
        }
    }

    private func modelText(_ ref: String?) -> String {
        guard let ref, !ref.isEmpty else { return "Pick a model" }
        return ref == "@session" ? "The chat's own model" : HarnessFormat.shortModel(ref)
    }

    private func setModel(_ field: ModelField, _ picked: ChatModel?) {
        guard let i = index else { return }
        let ref: String? = picked.map(Self.ref(for:))
        switch field {
        // A Computer step's "Automatic" is no model at all, not the chat's own.
        case .model: harness.nodes[i].model = harness.nodes[i].type == .computer ? ref : (ref ?? "@session")
        case .fallback: harness.nodes[i].fallbackModel = ref
        }
    }
}

/// One Route label: its name and what it means. The name is renamed on Return or
/// when the field loses focus, so a half-typed name never rewires anything; a
/// blank name or one another label has snaps back.
private struct HarnessLabelRow: View {
    let name: String
    @Binding var note: String
    let rename: (String) -> Bool

    @State private var draft: String
    @FocusState private var editing: Bool

    init(name: String, note: Binding<String>, rename: @escaping (String) -> Bool) {
        self.name = name
        _note = note
        self.rename = rename
        _draft = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label", text: $draft)
                .focused($editing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(commit)
            TextField("What it means (optional)", text: $note, axis: .vertical)
                .font(JcText.small)
                .lineLimit(1...4)
        }
        .onChange(of: name) { _, new in draft = new }
        .onChange(of: editing) { _, now in if !now { commit() } }
        // Done can close the sheet with the field still focused.
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != name else { draft = name; return }
        if !rename(draft) { draft = name }
    }
}

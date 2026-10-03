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
                    let start = CGPoint(x: a.x + w / 2, y: a.y + h)
                    let end = CGPoint(x: b.x + w / 2, y: b.y)
                    let dy = max(40, abs(end.y - start.y) / 2)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + dy),
                                  control2: CGPoint(x: end.x, y: end.y - dy))
                    ctx.stroke(path, with: .color(JcTheme.accent.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: edge.when == "handoff" ? [5, 4] : []))
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)

            ForEach(Array(harness.edges.enumerated()), id: \.offset) { index, edge in
                if let a = harness.node(edge.from), let b = harness.node(edge.to) {
                    Button { if !readOnly { editingEdge = index } } label: {
                        Text(edge.when == "always" ? "•" : edge.when)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(edgeHasProblem(index) ? JcTheme.danger : JcTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(JcTheme.surface))
                    }
                    .buttonStyle(.plain)
                    .position(x: (a.x + b.x) / 2 + w / 2, y: (a.y + h + b.y) / 2)
                }
            }

            ForEach(harness.nodes) { node in
                HarnessNodeCard(node: node,
                                problems: problems.filter { $0.node == node.id },
                                isWireSource: wiringFrom == node.id,
                                wiring: wiringFrom != nil,
                                canWireOut: !readOnly && node.type != .background && node.type != .review,
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
                let when = HarnessGraph.defaultWhen(harness, from: from, to: node.id)
                if !HarnessGraph.connect(&harness, from: from, to: node.id, when: when) {
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
        if let index = editingEdge, harness.edges.indices.contains(index),
           let source = harness.node(harness.edges[index].from) {
            ForEach(conditions(for: source), id: \.self) { when in
                Button(when) { harness.edges[index].when = when; editingEdge = nil }
            }
            Button("Remove wire", role: .destructive) {
                HarnessGraph.disconnect(&harness, index: index)
                editingEdge = nil
            }
        }
    }

    private func conditions(for source: HarnessNode) -> [String] {
        switch source.type {
        case .route:
            let labels = Set((source.labels ?? []) + (source.rules ?? []).map(\.label))
            return ["default"] + labels.sorted().map { "label:\($0)" }
        case .answer:
            return ["always", "handoff", "slow:20", "tools:5"]
        default:
            return ["always"]
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
                    ForEach([HarnessNodeType.answer, .route, .background, .review], id: \.self) { type in
                        Button(type.label) {
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

/// A step's settings: model, tools, delivery, route rules, instructions.
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
        .sheet(item: $pickingModel) { field in
            CatalogModelPickerSheet(title: field == .model ? "Step model" : "Fallback model",
                                    catalog: catalog,
                                    selectedID: nil,
                                    autoSubtitle: "The chat's own model.",
                                    load: { catalog = try? await ModelsAPI().list() },
                                    select: { picked in setModel(field, picked) })
        }
    }

    @ViewBuilder private func fields(_ i: Int) -> some View {
        let type = harness.nodes[i].type
        Section("Name") {
            TextField("Label", text: Binding(get: { harness.nodes[i].label ?? "" },
                                            set: { harness.nodes[i].label = $0.isEmpty ? nil : $0 }))
        }
        if type == .answer || type == .background || type == .review || (type == .route && harness.nodes[i].by == "model") {
            Section("Model") {
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
        if type != .message && type != .route {
            Section("Extra instructions") {
                TextField("Optional", text: Binding(get: { harness.nodes[i].instructions ?? "" },
                                                   set: { harness.nodes[i].instructions = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
                    .lineLimit(2...6)
            }
        }
    }

    @ViewBuilder private func routeFields(_ i: Int) -> some View {
        Section("Pick by") {
            Picker("Pick by", selection: Binding(get: { harness.nodes[i].by ?? "rules" },
                                                 set: { harness.nodes[i].by = $0 })) {
                Text("Rules").tag("rules")
                Text("A quick model").tag("model")
            }
            .pickerStyle(.segmented)
        }
        Section("Labels") {
            TextField("comma, separated", text: Binding(
                get: { (harness.nodes[i].labels ?? []).joined(separator: ", ") },
                set: { harness.nodes[i].labels = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
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
        let ref: String? = picked.map { m in
            m.id.hasPrefix("@") || m.providerID.isEmpty ? m.id : "@\(m.providerID):\(m.id)"
        }
        switch field {
        case .model: harness.nodes[i].model = ref ?? "@session"
        case .fallback: harness.nodes[i].fallbackModel = ref
        }
    }
}

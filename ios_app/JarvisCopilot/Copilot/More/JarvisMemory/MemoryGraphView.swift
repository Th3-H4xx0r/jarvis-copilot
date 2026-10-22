import SwiftUI

/// Calm tints per entity type; "You" and selection take the one accent.
enum MemoryGraphPalette {
    static func color(_ kind: MemoryEntityKind) -> Color {
        switch kind {
        case .person: return Color(jcHex: 0x8FB0F2)   // soft blue
        case .place: return Color(jcHex: 0x9BCB86)    // sage
        case .org: return Color(jcHex: 0xB9A2EC)      // lavender
        case .event: return Color(jcHex: 0xE9BC7E)    // sand
        case .topic: return Color(jcHex: 0xE29AB5)    // rose
        case .me: return JcTheme.accent
        }
    }
}

/// The Map half of Long-term Memory: filters, the force-directed graph, and the
/// node sheet.
struct MemoryMapScreen: View {
    let store: MemoryGraphStore
    /// The recall the map should open lit up for (the chat chip).
    var recall: MemoryRecall?
    /// Shown outside Long-term Memory (the chat chip's sheet), where the List
    /// view is not one tap away.
    var standalone = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var selected: MemoryNodeSelection?

    var body: some View {
        VStack(spacing: 0) {
            MemoryGraphFilterBar(store: store)
                .padding(.bottom, 6)
            if let recall = store.recall {
                recallBanner(recall)
            }
            ZStack {
                MemoryGraphCanvas(store: store,
                                  running: visible && scenePhase == .active,
                                  selectedID: selected?.id) { id in
                    guard id != MemoryGraph.meID else { return }
                    selected = MemoryNodeSelection(id: id)
                }
                overlay
            }
        }
        .onAppear {
            visible = true
            Task {
                if let recall, store.recall?.id != recall.id {
                    await store.showRecall(recall)
                } else {
                    await store.loadIfNeeded()
                }
            }
        }
        .onDisappear { visible = false }
        .sheet(item: $selected) { selection in
            MemoryNodeSheet(graph: store, id: selection.id)
                .onAppear { store.sheetOpen = true }
                .onDisappear { store.sheetOpen = false }
                .presentationDetents([.medium, .large])
                .presentationBackground(JcTheme.surface)
        }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }))
    }

    @ViewBuilder private var overlay: some View {
        if store.loading && store.graph.isEmpty {
            ProgressView().tint(JcTheme.accent)
        } else if let error = store.error, store.graph.isEmpty {
            CenteredMessage(text: error, color: JcTheme.danger) { Task { await store.load() } }
        } else if store.hasLoaded && store.graph.isEmpty && !store.loading {
            JcEmptyState(symbol: "point.3.connected.trianglepath.dotted",
                         title: "Nothing mapped yet",
                         subtitle: !store.filters.isDefault ? "Nothing matches these filters."
                            : standalone ? "Open Long-term Memory → List to run Cleanup & map."
                            : "Run Cleanup & map in the List view.")
                .allowsHitTesting(false)
        }
    }

    private func recallBanner(_ recall: MemoryRecall) -> some View {
        HStack(spacing: 10) {
            JcIcon("brain", size: 14).foregroundStyle(JcTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Memories used for")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                Text(recall.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show all") { Task { await store.clearRecall() } }
                .buttonStyle(.jcGlass(compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct MemoryNodeSelection: Identifiable, Equatable {
    let id: String
}

// MARK: - Filters

struct MemoryGraphFilterBar: View {
    let store: MemoryGraphStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MemoryEntityKind.filterable) { kind in
                    let on = store.filters.types.contains(kind)
                    Button {
                        var f = store.filters
                        f.toggle(kind)
                        apply(f)
                    } label: {
                        chip(kind.chipLabel, dot: MemoryGraphPalette.color(kind), on: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Menu {
                    Picker("Time", selection: Binding(get: { store.filters.time },
                                                      set: { var f = store.filters; f.time = $0; apply(f) })) {
                        ForEach(MemoryTimeRange.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    menuChip(store.filters.time.label, symbol: "clock", active: store.filters.time != .all)
                }
                Menu {
                    Picker("Source", selection: Binding(get: { store.filters.source },
                                                        set: { var f = store.filters; f.source = $0; apply(f) })) {
                        ForEach(MemorySourceFilter.allCases) { source in
                            Label(source.label, jcIcon: source.symbol).tag(source)
                        }
                    }
                } label: {
                    menuChip(store.filters.source.label, symbol: store.filters.source.symbol,
                             active: store.filters.source != .all)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func apply(_ f: MemoryGraphFilters) {
        Task { await store.setFilters(f) }
    }

    private func chip(_ title: String, dot: Color, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? dot : .clear)
                .overlay(Circle().strokeBorder(dot.opacity(on ? 0 : 0.7), lineWidth: 1))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? JcTheme.text : JcTheme.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white.opacity(on ? 0.10 : 0.04), in: Capsule())
        .contentShape(Capsule())
    }

    private func menuChip(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            JcIcon(symbol, size: 11)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            JcIcon("chevron.down", size: 8)
        }
        .foregroundStyle(active ? JcTheme.accent : JcTheme.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white.opacity(active ? 0.10 : 0.06), in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Canvas

/// The force-directed graph. A TimelineView steps the layout once per frame and
/// pauses whenever it settles, the map leaves the screen, or the app goes to the
/// background — a resting map draws nothing until a finger moves it.
struct MemoryGraphCanvas: View {
    let store: MemoryGraphStore
    /// On screen with the app in front.
    let running: Bool
    let selectedID: String?
    let onTap: (String) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// Shrinks a big settled graph to fit the view (never enlarges).
    @State private var fit: CGFloat = 1
    @GestureState private var pinch = PinchState()
    @GestureState private var drag: CGSize = .zero
    /// A pinch is on: one-finger drag moves are ignored so the pan doesn't drift.
    @State private var pinching = false
    /// This drag overlapped a pinch, so its translation is not committed.
    @State private var dragSawPinch = false
    /// Colours, labels and the selection's neighbours, rebuilt once per graph
    /// change, not per frame.
    @State private var cache = MemoryGraphDrawCache()

    private static let zoomRange: ClosedRange<CGFloat> = 0.35...4

    struct PinchState: Equatable {
        var scale: CGFloat = 1
        var anchor: CGPoint = .zero
    }

    var body: some View {
        // Read here, not in the Canvas closure, so observation redraws on change.
        let graph = store.graph
        let version = store.layoutVersion
        let paused = !running || store.isSettled
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
                let viewport = liveViewport(geo.size)
                Canvas(rendersAsynchronously: false) { ctx, _ in
                    cache.prepare(graph: graph, version: version, selected: selectedID)
                    draw(&ctx, graph: graph, viewport: viewport)
                }
                .onChange(of: context.date) { _, _ in store.tick() }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let viewport = MemoryGraphViewport(size: geo.size, pan: pan, zoom: zoom * fit)
                    if let id = MemoryGraphHitTest.node(at: value.location, graph: graph,
                                                        sim: store.layout, viewport: viewport) {
                        onTap(id)
                    }
                })
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in
                        if !pinching { state = value.translation }
                    }
                    .onEnded { value in
                        defer { dragSawPinch = false }
                        guard !dragSawPinch, !pinching else { return }
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in
                        state = PinchState(scale: value.magnification, anchor: value.startLocation)
                    }
                    .onChanged { _ in
                        if !pinching { pinching = true }
                        dragSawPinch = true
                    }
                    .onEnded { value in
                        pinching = false
                        let next = clampZoom(zoom * value.magnification)
                        pan = Self.panAfterZoom(pan, by: next / zoom, around: value.startLocation, in: geo.size)
                        zoom = next
                    })
            .onChange(of: store.isSettled, initial: true) { _, settled in
                if settled { fitToView(geo.size, graph: graph) }
            }
            // One element per node for VoiceOver (the drawing itself is opaque to it).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Memory map")
            .accessibilityValue("\(max(0, graph.nodeIDs.count - 1)) people, places and topics around you")
            .accessibilityChildren {
                ForEach(Self.accessibleNodes(graph)) { node in
                    Rectangle()
                        .accessibilityElement()
                        .accessibilityLabel(node.label)
                        .accessibilityValue("\(node.kind.label), \(node.weight == 1 ? "1 memory" : "\(node.weight) memories")")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onTap(node.id) }
                }
            }
            // Outside the combined element, so VoiceOver reaches it.
            .overlay(alignment: .bottomTrailing) {
                if zoom != 1 || pan != .zero {
                    GlassIconButton(symbol: "scope", size: 40, iconSize: 17) {
                        withAnimation(.smooth(duration: 0.3)) {
                            zoom = 1
                            pan = .zero
                        }
                    }
                    .accessibilityLabel("Recenter")
                    .padding(16)
                }
            }
        }
        .clipped()
    }

    /// Heaviest first, without You.
    static func accessibleNodes(_ graph: MemoryGraph) -> [MemoryGraphNode] {
        graph.nodes.filter { $0.id != MemoryGraph.meID }.sorted { $0.weight > $1.weight }
    }

    /// Zooming by `k` around a screen point keeps the world point under it still.
    static func panAfterZoom(_ pan: CGSize, by k: CGFloat, around anchor: CGPoint, in size: CGSize) -> CGSize {
        let cx = anchor.x - size.width / 2, cy = anchor.y - size.height / 2
        return CGSize(width: cx * (1 - k) + pan.width * k, height: cy * (1 - k) + pan.height * k)
    }

    private func liveViewport(_ size: CGSize) -> MemoryGraphViewport {
        let z = clampZoom(zoom * pinch.scale)
        var p = pan
        if pinch.scale != 1 { p = Self.panAfterZoom(pan, by: z / zoom, around: pinch.anchor, in: size) }
        if !pinching { p.width += drag.width; p.height += drag.height }
        return MemoryGraphViewport(size: size, pan: p, zoom: z * fit)
    }

    /// Once the layout rests, scale it down if it spills past the view.
    private func fitToView(_ size: CGSize, graph: MemoryGraph) {
        guard size.width > 0, size.height > 0 else { return }
        let sim = store.layout
        var extent: CGFloat = 1
        for id in graph.nodeIDs {
            guard let p = sim.position(id), let r = sim.radius(id) else { continue }
            extent = max(extent, abs(p.x) + CGFloat(r) + 8, abs(p.y) + CGFloat(r) + 24)
        }
        let room = min(size.width, size.height) / 2 - 12
        let next = min(1, max(0.4, room / extent))
        guard abs(next - fit) > 0.02 else { return }
        withAnimation(.smooth(duration: 0.35)) { fit = next }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, z))
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, graph: MemoryGraph, viewport: MemoryGraphViewport) {
        let sim = store.layout
        let lit = graph.highlight
        let dimming = !lit.isEmpty
        let focus = cache.focus

        func isLit(_ id: String) -> Bool { !dimming || lit.contains(id) || id == MemoryGraph.meID }

        // Edges under the nodes.
        let edgeScale = min(1.4, max(0.6, viewport.zoom))
        for edge in cache.edges {
            guard let a = sim.position(edge.a), let b = sim.position(edge.b) else { continue }
            var path = Path()
            path.move(to: viewport.toScreen(a))
            path.addLine(to: viewport.toScreen(b))
            let opacity: Double
            if edge.touchesSelection {
                opacity = 0.55
            } else if dimming {
                opacity = isLit(edge.a) && isLit(edge.b) ? 0.38 : 0.04
            } else {
                opacity = 0.13
            }
            ctx.stroke(path, with: .color((edge.touchesSelection ? JcTheme.accent : Color.white).opacity(opacity)),
                       lineWidth: edge.width * edgeScale)
        }

        // Nodes, then every label on top of every node.
        var labels: [(String, Bool, CGPoint)] = []
        for style in cache.nodes {
            guard let p = sim.position(style.id), let r0 = sim.radius(style.id) else { continue }
            let center = viewport.toScreen(p)
            let r = CGFloat(r0) * viewport.zoom
            let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            let dim = !isLit(style.id) || (!focus.isEmpty && !focus.contains(style.id) && !dimming)
            let alpha = dim ? (dimming ? 0.16 : 0.45) : 1

            if style.kind == .me {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.45, dy: -r * 0.45)),
                         with: .color(JcTheme.accent.opacity(0.14)))
                ctx.fill(Path(ellipseIn: rect), with: .color(JcTheme.accent))
            } else {
                // An opaque backing so edges never show through a node.
                ctx.fill(Path(ellipseIn: rect), with: .color(JcTheme.bg))
                ctx.fill(Path(ellipseIn: rect), with: .color(style.color.opacity(0.9 * alpha)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.22 * alpha)), lineWidth: 0.8)
            }
            if dimming && lit.contains(style.id) {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                           with: .color(JcTheme.accent.opacity(0.8)), lineWidth: 1.5)
            }
            if style.pinned {
                let pin = CGRect(x: center.x + r * 0.55, y: center.y - r * 0.95, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: pin), with: .color(.white.opacity(0.9 * alpha)))
            }
            if style.id == selectedID {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                           with: .color(JcTheme.accent), lineWidth: 2.5)
            }

            // Labels: You, the selection, lit nodes, bigger nodes, and all when zoomed in.
            let showLabel = style.kind == .me || style.id == selectedID || (dimming && lit.contains(style.id))
                || r >= 12 || viewport.zoom >= 1.6 || focus.contains(style.id)
            guard showLabel, !(dim && dimming) else { continue }
            labels.append((style.id, dim, CGPoint(x: center.x, y: center.y + r + 9)))
        }
        for (id, dim, point) in labels {
            if let text = cache.label(id, dim: dim, in: ctx) { ctx.draw(text, at: point, anchor: .center) }
        }
    }
}

/// What drawing needs that only changes with the graph or the selection.
final class MemoryGraphDrawCache {
    struct NodeStyle {
        let id: String
        let kind: MemoryEntityKind
        let color: Color
        let label: String
        let pinned: Bool
    }

    struct EdgeStyle {
        let a: String
        let b: String
        let width: Double
        let touchesSelection: Bool
    }

    private var key: (version: Int, nodes: Int, edges: Int, selected: String?)?
    private(set) var nodes: [NodeStyle] = []
    private(set) var edges: [EdgeStyle] = []
    /// The selection and its neighbours (empty with nothing selected).
    private(set) var focus: Set<String> = []
    private var labels: [String: GraphicsContext.ResolvedText] = [:]

    func prepare(graph: MemoryGraph, version: Int, selected: String?) {
        let next = (version, graph.nodeIDs.count, graph.edges.count, selected)
        if let key, key == next { return }
        key = next
        nodes = graph.nodes.map { node in
            NodeStyle(id: node.id, kind: node.kind, color: MemoryGraphPalette.color(node.kind),
                      label: node.label.count > 24 ? String(node.label.prefix(23)) + "…" : node.label,
                      pinned: node.pinned)
        }
        edges = graph.edges.map { edge in
            EdgeStyle(a: edge.a, b: edge.b,
                      width: 0.6 + min(2.2, log(Double(max(1, edge.weight)) + 1) * 0.45),
                      touchesSelection: selected != nil && (edge.a == selected || edge.b == selected))
        }
        focus = selected.map { Set([$0] + graph.neighbors(of: $0)) } ?? []
        labels = [:]
    }

    /// The laid-out label, resolved once and reused every frame after.
    func label(_ id: String, dim: Bool, in ctx: GraphicsContext) -> GraphicsContext.ResolvedText? {
        let key = dim ? id + "|dim" : id
        if let hit = labels[key] { return hit }
        guard let style = nodes.first(where: { $0.id == id }) else { return nil }
        let me = style.kind == .me
        let text = Text(style.label)
            .font(.system(size: me ? 12.5 : 11, weight: me ? .semibold : .medium))
            .foregroundColor(JcTheme.text.opacity(dim ? 0.5 : 0.92))
        let resolved = ctx.resolve(text)
        labels[key] = resolved
        return resolved
    }
}

// MARK: - Chat chip

/// Under a Jarvis reply that drew on memory: opens the map lit up on what it used.
struct MemoryUsedChip: View {
    let recall: MemoryRecall
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                JcIcon("brain", size: 11)
                Text(recall.memoryIDs.count == 1 ? "1 memory used" : recall.memoryIDs.isEmpty
                     ? "Memories used" : "\(recall.memoryIDs.count) memories used")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(JcTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the memory map lit up on what this reply used")
    }
}

/// The map in a sheet, lit up for one recall (from the chat chip).
struct MemoryRecallMapSheet: View {
    let recall: MemoryRecall
    @State private var store = MainActor.assumeIsolated { MemoryGraphStore() }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MemoryMapScreen(store: store, recall: recall, standalone: true)
                .jcScreen("Memory map")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // Panning the map must not swipe the sheet away.
        .interactiveDismissDisabled()
    }
}

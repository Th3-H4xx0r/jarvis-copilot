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
                         subtitle: store.filters.isDefault
                            ? "Run Cleanup & map in the List view."
                            : "Nothing matches these filters.")
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
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let zoomRange: ClosedRange<CGFloat> = 0.35...4

    private var liveZoom: CGFloat { clampZoom(zoom * pinch) * fit }
    private var livePan: CGSize {
        let k = clampZoom(zoom * pinch) / zoom
        return CGSize(width: pan.width * k + drag.width, height: pan.height * k + drag.height)
    }

    var body: some View {
        // Read here, not in the Canvas closure, so observation redraws on change.
        let graph = store.graph
        let version = store.layoutVersion
        let paused = !running || store.isSettled
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
                let viewport = MemoryGraphViewport(size: geo.size, pan: livePan, zoom: liveZoom)
                Canvas(rendersAsynchronously: false) { ctx, _ in
                    _ = version
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
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        let next = clampZoom(zoom * value.magnification)
                        let k = next / zoom
                        pan = CGSize(width: pan.width * k, height: pan.height * k)
                        zoom = next
                    })
            .onChange(of: store.isSettled, initial: true) { _, settled in
                if settled { fitToView(geo.size, graph: graph) }
            }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory map, \(max(0, graph.nodeIDs.count - 1)) people, places and topics around you")
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
        let focus: Set<String> = selectedID.map { Set([$0] + graph.neighbors(of: $0)) } ?? []

        func isLit(_ id: String) -> Bool { !dimming || lit.contains(id) || id == MemoryGraph.meID }

        // Edges under the nodes.
        for edge in graph.edges {
            guard let a = sim.position(edge.a), let b = sim.position(edge.b) else { continue }
            var path = Path()
            path.move(to: viewport.toScreen(a))
            path.addLine(to: viewport.toScreen(b))
            let touchesSelection = selectedID != nil && (edge.a == selectedID || edge.b == selectedID)
            let opacity: Double
            if touchesSelection {
                opacity = 0.55
            } else if dimming {
                opacity = isLit(edge.a) && isLit(edge.b) ? 0.38 : 0.04
            } else {
                opacity = 0.13
            }
            let width = (0.6 + min(2.2, log(Double(max(1, edge.weight)) + 1) * 0.45)) * min(1.4, max(0.6, viewport.zoom))
            ctx.stroke(path, with: .color((touchesSelection ? JcTheme.accent : Color.white).opacity(opacity)),
                       lineWidth: width)
        }

        // Nodes, then every label on top of every node.
        var labels: [(Text, CGPoint)] = []
        for node in graph.nodes {
            guard let p = sim.position(node.id), let r0 = sim.radius(node.id) else { continue }
            let center = viewport.toScreen(p)
            let r = CGFloat(r0) * viewport.zoom
            let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            let kind = node.kind
            let color = MemoryGraphPalette.color(kind)
            let dim = !isLit(node.id) || (!focus.isEmpty && !focus.contains(node.id) && !dimming)
            let alpha = dim ? (dimming ? 0.16 : 0.45) : 1

            if kind == .me {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.45, dy: -r * 0.45)),
                         with: .color(JcTheme.accent.opacity(0.14)))
                ctx.fill(Path(ellipseIn: rect), with: .color(JcTheme.accent))
            } else {
                // An opaque backing so edges never show through a node.
                ctx.fill(Path(ellipseIn: rect), with: .color(JcTheme.bg))
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9 * alpha)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.22 * alpha)), lineWidth: 0.8)
            }
            if dimming && lit.contains(node.id) {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                           with: .color(JcTheme.accent.opacity(0.8)), lineWidth: 1.5)
            }
            if node.pinned {
                let pin = CGRect(x: center.x + r * 0.55, y: center.y - r * 0.95, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: pin), with: .color(.white.opacity(0.9 * alpha)))
            }
            if node.id == selectedID {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                           with: .color(JcTheme.accent), lineWidth: 2.5)
            }

            // Labels: You, the selection, lit nodes, bigger nodes, and all when zoomed in.
            let showLabel = kind == .me || node.id == selectedID || (dimming && lit.contains(node.id))
                || r >= 12 || viewport.zoom >= 1.6 || focus.contains(node.id)
            guard showLabel, !(dim && dimming) else { continue }
            let label = node.label.count > 24 ? String(node.label.prefix(23)) + "…" : node.label
            let text = Text(label)
                .font(.system(size: kind == .me ? 12.5 : 11, weight: kind == .me ? .semibold : .medium))
                .foregroundColor(JcTheme.text.opacity(dim ? 0.5 : 0.92))
            labels.append((text, CGPoint(x: center.x, y: center.y + r + 9)))
        }
        for (text, point) in labels { ctx.draw(text, at: point, anchor: .center) }
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
            MemoryMapScreen(store: store, recall: recall)
                .jcScreen("Memory map")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

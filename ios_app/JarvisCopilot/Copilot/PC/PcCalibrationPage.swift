import SceneKit
import SwiftUI

/// Show Jarvis each part, the OpenRGB way: every connector as a row of LED squares. Drag its slider to the
/// number of LEDs that light on the PC, paint a run of squares (they light up white on the PC), then tap
/// the part(s) on the model they belong to. Saves the LED map.
struct PcCalibrationPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var board = PcCalibrationBoard(connectors: [])
    @State private var active = 0
    @State private var counts: [Double] = []
    @State private var paint: ClosedRange<Int>?
    @State private var dragStart: Int?
    @State private var picked: [PcLedKey] = []
    @State private var error: String?
    @State private var saving = false
    @State private var queue = PcProbeQueue { args in await PcStore.shared.probe(args) }
    @State private var placing = false
    @State private var lastTap: [String] = []

    /// Painted parts glow white on the model as you go (drawn strips too).
    static let preview = PcLightingState(on: true, brightness: 70, t0: 0, frozenAt: 1, stillInGames: false, rev: 0,
                                                 parts: Dictionary(uniqueKeysWithValues: PcPart.allCases.map {
                                                     ($0.rawValue, PcPartLight(effect: "static", color: "#ffffff", speed: 5)) }))
    private var highlights: [String] {
        let fans = picked.map { k in k.part == .cooler || k.part == .strip ? "part.\(k.part.rawValue)" : "fan.\(k.part.rawValue).\(k.index)" }
        return fans.isEmpty ? lastTap : fans
    }

    private var store: PcStore { .shared }

    var body: some View {
        ScrollView {
            JcPageColumn {
              VStack(alignment: .leading, spacing: 14) {
                PcModelView(state: Self.preview, map: board.map(), lit: true, onTapLED: { key in tapped(key) },
                            onTapTarget: { t in lastTap = t.name.map { [$0] } ?? [] },
                            highlighted: highlights, workLight: true)
                    .frame(height: 280)
                    .background(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
                Text("Drag a connector's slider until its LEDs on the PC stop lighting, paint a run of squares, then tap Assign to find them on the model.")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                ForEach(Array(board.connectors.enumerated()), id: \.offset) { i, k in
                    connectorCard(i, k)
                }
                if !board.connectors.isEmpty {
                    if !board.missingParts.isEmpty {
                        Text("Not painted yet: \(board.missingParts.map { $0.label }.joined(separator: ", ")).")
                            .font(.footnote).foregroundStyle(JcTheme.muted)
                    }
                    Button { Task { await save() } } label: { PcPrimaryLabel(text: saving ? "Saving…" : "Save") }
                        .buttonStyle(.plain).disabled(saving)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(JcTheme.danger)
                }
              }
            }
        }
        .jcPageChrome("Show Jarvis each part", header: .inline)
        .fullScreenCover(isPresented: $placing) {
            if let r = paint, board.connectors.indices.contains(active) {
                let had = board.mapped(active, r)
                PcPlaceView(connector: board.connectors[active].name, index: active, range: r, board: board,
                            picked: picked.isEmpty ? had.fans : picked, startLine: had.line,
                            keepLit: { light(active, range: r) }) { fans, line in
                    board.place(active, r, fans: fans, line: line)
                    paint = nil; picked = []
                    light(active)
                }
            }
        }
        .task { start() }
        .onDisappear { Task { _ = await store.probe(["clear": true]) } }
    }

    // MARK: one connector

    @ViewBuilder private func connectorCard(_ i: Int, _ k: PcCalibrationBoard.Connector) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        Text(k.name.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(JcTheme.muted)
        JcCard {
            VStack(alignment: .leading, spacing: 12) {
                squares(i, k)
                if k.resizable {
                    HStack {
                        Slider(value: Binding(get: { counts.indices.contains(i) ? counts[i] : 0 },
                                              set: { v in if counts.indices.contains(i) { counts[i] = v }; setCount(i, Int(v)) }),
                               in: 0...Double(max(1, k.max)), step: 1)
                        Text("\(k.leds) LEDs").font(.footnote.monospacedDigit()).foregroundStyle(JcTheme.muted).frame(width: 64)
                    }
                }
                if active == i, let r = paint {
                    Text("LEDs \(r.lowerBound + 1)–\(r.upperBound + 1) are lit on the PC.").font(.subheadline)
                    HStack(spacing: 10) {
                        Button { placing = true } label: { PcPrimaryLabel(text: "Assign") }.buttonStyle(.plain)
                        Button("Clear") { paint = nil; picked = []; light(i) }.buttonStyle(.jcGlass)
                    }
                }
                if k.leds > 1 {
                    HStack(spacing: 8) {
                        Text("Colours").font(.footnote).foregroundStyle(JcTheme.muted)
                        Picker("Colour order", selection: Binding(get: { k.order }, set: { o in board.setOrder(i, o); testColour(i) })) {
                            Text("RGB").tag("rgb")
                            Text("GRB").tag("grb")
                        }
                        .pickerStyle(.menu)
                        Button("Show red") { testColour(i) }.buttonStyle(.jcGlass)
                    }
                }
            }
        }
        }
    }

    /// The LED squares, coloured by the part painted there; drag across them to paint a run.
    private func squares(_ i: Int, _ k: PcCalibrationBoard.Connector) -> some View {
        let n = max(0, k.leds)
        let perRow = 20
        return GeometryReader { geo in
            let side = min(14, (geo.size.width - CGFloat(perRow - 1) * 3) / CGFloat(perRow))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<max(1, (n + perRow - 1) / perRow), id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<min(perRow, max(0, n - row * perRow)), id: \.self) { col in
                            let led = row * perRow + col
                            RoundedRectangle(cornerRadius: 2)
                                .fill(fill(i, led))
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let led = ledAt(g.location, side: side, perRow: perRow, n: n)
                guard let led else { return }
                if active != i || dragStart == nil { active = i; dragStart = led; picked = [] }
                paint = min(dragStart!, led)...max(dragStart!, led)
                light(i, range: paint)
            }.onEnded { _ in dragStart = nil })
        }
        .frame(height: CGFloat(max(1, (n + perRow - 1) / perRow)) * 17)
    }

    private func ledAt(_ p: CGPoint, side: CGFloat, perRow: Int, n: Int) -> Int? {
        let col = Int(p.x / (side + 3)), row = Int(p.y / (side + 3))
        guard col >= 0, col < perRow, row >= 0 else { return nil }
        let led = row * perRow + col
        return led < n ? led : nil
    }

    private func fill(_ i: Int, _ led: Int) -> Color {
        if active == i, let r = paint, r.contains(led) { return .white }
        switch board.part(i, led: led) {
        case .top: return Color(hexString: "#0a84ff")
        case .rear: return Color(hexString: "#22d3ee")
        case .bottom: return Color(hexString: "#30d158")
        case .cooler: return Color(hexString: "#ff9f0a")
        case .strip: return Color(hexString: "#bf5af2")
        case nil: return Color.white.opacity(0.12)
        }
    }

    // MARK: actions

    private func name(_ k: PcLedKey) -> String { k.part.count > 1 ? "\(k.part.label) \(k.index + 1)" : k.part.label }

    private func start() {
        guard board.connectors.isEmpty else { return }
        board = PcCalibrationBoard(connectors: store.controllers.flatMap { c in
            c.zones.map { .init(controller: c.index, zone: $0.index, name: $0.name, max: $0.max ?? $0.leds,
                                resizable: $0.resizable ?? false, leds: $0.leds) }
        })
        counts = board.connectors.map { Double($0.leds) }
        if board.connectors.isEmpty { error = "OpenRGB found no lights — run setup first" }
    }

    private func setCount(_ i: Int, _ n: Int) {
        board.setLEDs(i, n)
        paint = nil; picked = []
        let k = board.connectors[i]
        queue.submit(["controller": k.controller, "zone": k.zone, "resize": max(1, n), "range": [0, max(0, n)]])
    }

    private func light(_ i: Int, range: ClosedRange<Int>? = nil) {
        let k = board.connectors[i]
        let r = range ?? 0...max(0, k.leds - 1)
        queue.submit(["controller": k.controller, "zone": k.zone, "range": [r.lowerBound, r.count]])
    }

    /// Lights the connector red through its chosen colour order: pick the order where they look red.
    private func testColour(_ i: Int) {
        let k = board.connectors[i]
        let raw = k.order == "grb" ? "#00ff00" : "#ff0000"
        queue.submit(["controller": k.controller, "zone": k.zone, "range": [0, max(0, k.leds)], "color": raw])
    }

    private func tapped(_ key: PcLedKey) {
        guard paint != nil else { return }
        let fan = PcLedKey(part: key.part, index: key.index, led: 0)
        if let at = picked.firstIndex(of: fan) { picked.remove(at: at) } else { picked.append(fan) }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let e = await store.putMap(board.map()) { error = e; return }
        _ = await store.probe(["clear": true])
        dismiss()
    }
}

/// Full screen, for finding the lit LEDs on the model: a lit backdrop and bright work light; drag to
/// turn, pinch to zoom, two fingers to move, or pick a view. Tap the fan(s) that lit up, or draw where the
/// strip runs, then Assign. The painted LEDs stay lit on the PC the whole time.
struct PcPlaceView: View {
    let connector: String
    let index: Int
    let range: ClosedRange<Int>
    let board: PcCalibrationBoard
    var picked: [PcLedKey] = []
    var startLine: [[Double]]? = nil
    var keepLit: () -> Void = {}
    let onAssign: ([PcLedKey], [[Double]]?) -> Void

    enum Tool: Hashable { case tap, draw }

    @Environment(\.dismiss) private var dismiss
    @State private var fans: [PcLedKey] = []
    @State private var line: [[Double]]?
    @State private var tool: Tool = .tap
    @State private var pose: PcModel.Pose = .hero
    @State private var poseToken = 0
    @State private var lastTap: [String] = []
    /// Newest last, for Undo: a fan tapped in (nil = the strip drawn).
    @State private var history: [PcLedKey?] = []

    /// The board with this choice applied: the run glows where it would go.
    private var preview: PcLedMap {
        var b = board
        b.place(index, range, fans: fans, line: line)
        return b.map()
    }

    private var highlights: [String] {
        return fans.isEmpty && line == nil ? lastTap : fans.map(Self.node)
    }

    static func node(_ k: PcLedKey) -> String {
        k.part == .cooler || k.part == .strip ? "part.\(k.part.rawValue)" : "fan.\(k.part.rawValue).\(k.index)"
    }

    private var chosen: String {
        let names = fans.map { $0.part.count > 1 ? "\($0.part.label) \($0.index + 1)" : $0.part.label }
        return (names + (line == nil ? [] : ["Strip (drawn)"])).joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.46), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            PcModelView(state: PcCalibrationPage.preview, map: preview, lit: true,
                        onTapLED: tool == .tap ? { k in toggle(k) } : nil,
                        onTapTarget: { t in lastTap = t.name.map { [$0] } ?? [] },
                        highlighted: highlights, drawing: tool == .draw,
                        onDraw: { a, b in
                            line = [[Double(a.x), Double(a.y), Double(a.z)], [Double(b.x), Double(b.y), Double(b.z)]]
                            history.append(nil)
                        },
                        workLight: true, camera: tool == .draw ? .zoomOnly : .orbit, pose: pose, poseToken: poseToken)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer()
                panel
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { fans = picked; line = startLine }
        .task {
            // A test lighting lapses after a minute on the PC: keep the run lit while it's being placed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                if !Task.isCancelled { keepLit() }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { circle("xmark") }.accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 2) {
                Text(connector).font(.headline)
                Text("LEDs \(range.lowerBound + 1)–\(range.upperBound + 1) are lit white on the PC")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(PcModel.Pose.allCases) { p in Button(p.label) { pose = p; poseToken += 1 } }
            } label: { circle("cube") }
            .accessibilityLabel("Views")
            Button { pose = .hero; poseToken += 1 } label: { circle("arrow.counterclockwise") }
                .accessibilityLabel("Reset view")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tool", selection: $tool) {
                Text("Tap a part").tag(Tool.tap)
                Text("Draw strip").tag(Tool.draw)
            }
            .pickerStyle(.segmented)
            Text(tool == .tap ? "Drag to turn · pinch to zoom · two fingers to move. Tap every part that lit up — chained parts can share the same LEDs."
                              : "Drag along where the strip runs · pinch to zoom. Fans you tap stay picked too.")
                .font(.footnote).foregroundStyle(.white.opacity(0.8))
            if !chosen.isEmpty { Text(chosen).font(.subheadline.weight(.semibold)) }
            HStack(spacing: 10) {
                Button("Undo") { undo() }
                    .buttonStyle(.jcGlass)
                    .disabled(fans.isEmpty && line == nil)
                Button { onAssign(fans, line); dismiss() } label: {
                    PcPrimaryLabel(text: "Assign LEDs \(range.lowerBound + 1)–\(range.upperBound + 1)")
                }
                .buttonStyle(.plain)
                .disabled(fans.isEmpty && line == nil)
                .opacity(fans.isEmpty && line == nil ? 0.5 : 1)
            }
        }
        .padding(16)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func circle(_ symbol: String) -> some View {
        JcIcon(symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.55), in: Circle())
    }

    private func toggle(_ key: PcLedKey) {
        let fan = PcLedKey(part: key.part, index: key.index, led: 0)
        if let at = fans.firstIndex(of: fan) { fans.remove(at: at) } else { fans.append(fan); history.append(fan) }
    }

    private func undo() {
        while let last = history.popLast() {
            if let fan = last { if let at = fans.firstIndex(of: fan) { fans.remove(at: at); return } }
            else if line != nil { line = nil; return }
        }
        if !fans.isEmpty { fans.removeLast() } else { line = nil }   // picked before this view opened
    }
}

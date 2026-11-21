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
    @State private var drawing = false
    @State private var lastTap: [String] = []

    /// Painted parts glow white on the model as you go (drawn strips too).
    private static let preview = PcLightingState(on: true, brightness: 70, t0: 0, frozenAt: 1, stillInGames: false, rev: 0,
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
                            highlighted: highlights, drawing: drawing,
                            onDraw: { a, b in drew(a, b) })
                    .frame(height: 280)
                    .overlay(alignment: .top) {
                        if drawing {
                            Text("Drag along the strip on the model").font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.black.opacity(0.7), in: Capsule())
                        }
                    }
                Text("Drag a connector's slider until its LEDs on the PC stop lighting, paint a run of squares, then tap the fan or cooler on the model, or draw where the strip runs.")
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
                    Text(picked.isEmpty ? "LEDs \(r.lowerBound + 1)–\(r.upperBound + 1) are lit on the PC. Tap the fan or cooler on the model, or draw the strip."
                                        : picked.map(name).joined(separator: " · "))
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        Button("Assign") { assign() }.buttonStyle(.jcGlass).disabled(picked.isEmpty)
                        Button(drawing ? "Drawing…" : "Draw strip") { drawing.toggle(); picked = [] }.buttonStyle(.jcGlass)
                        Button("Clear") { paint = nil; picked = []; drawing = false; light(i) }.buttonStyle(.jcGlass)
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

    private func assign() {
        guard let r = paint, let first = picked.first else { return }
        board.assign(active, r, part: first.part, index: first.index, also: Array(Set(picked.dropFirst().map(\.part))))
        paint = nil; picked = []
        light(active)
    }

    /// A strip drawn on the model for the painted run.
    private func drew(_ a: SCNVector3, _ b: SCNVector3) {
        guard let r = paint else { return }
        board.assign(active, r, part: .strip, index: 0,
                     line: [[Double(a.x), Double(a.y), Double(a.z)], [Double(b.x), Double(b.y), Double(b.z)]])
        drawing = false; paint = nil; picked = []
        light(active)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let e = await store.putMap(board.map()) { error = e; return }
        _ = await store.probe(["clear": true])
        dismiss()
    }
}

import SwiftUI

/// Show Jarvis each part: for every OpenRGB connector, slide a single lit LED along the chain, tap the
/// fan it's on, tap where its first LED is and say which way they run. Saves the LED map.
struct PcCalibrationPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cal: PcCalibration?
    @State private var led: Double = 0
    @State private var target: PcLedKey?
    /// Other fans that lit at the same time (a hub that copies one connector to several fans).
    @State private var extras: [PcLedKey] = []
    @State private var seenRed: String?
    @State private var queue = PcProbeQueue { args in await PcStore.shared.probe(args) }
    @State private var phase: Phase = .scrub
    @State private var startDeg: Double?
    @State private var error: String?
    @State private var saving = false

    private enum Phase { case scrub, start, direction }
    private var store: PcStore { .shared }

    var body: some View {
        ScrollView {
            JcPageColumn {
                PcModelView(state: store.state, map: nil, lit: false,
                            onTapLED: { key in tapped(key) })
                    .frame(height: 300)
                if let cal, let job = cal.current {
                    JcSectionLabel("Connector \(cal.zoneIndex + 1) of \(cal.zones.count)")
                    JcCard { steps(cal, job) }
                } else if let cal {
                    JcCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cal.missingParts.isEmpty ? "Every part is mapped." :
                                    "Not found: \(cal.missingParts.map { $0.label }.joined(separator: ", ")). They'll stay dark.")
                                .font(.subheadline).foregroundStyle(JcTheme.muted)
                            Button { Task { await save(cal) } } label: { PcPrimaryLabel(text: saving ? "Saving…" : "Save") }
                                .buttonStyle(.plain).disabled(saving)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(JcTheme.danger)
                }
            }
        }
        .jcPageChrome("Show Jarvis each part", header: .inline)
        .task { start() }
        .onDisappear { Task { _ = await store.probe(["clear": true]) } }
    }

    @ViewBuilder private func steps(_ cal: PcCalibration, _ job: PcCalibration.ZoneJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if cal.needsSize, let range = cal.scrubRange {
                Text("Slide until the light reaches the last LED that lights on this connector.")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                slider(range)
                HStack {
                    Button("Last LED") {
                        mutate { $0.setSize(lastLit: Int(led)) }; led = 0
                        if self.cal?.needsOrder == true { probe(0, color: "#ff0000") } else { probe(0) }
                    }.buttonStyle(.jcGlass)
                    Button("Nothing lights") { mutate { $0.skipZone() }; led = 0; probe(0) }.buttonStyle(.jcGlass)
                }
            } else if cal.needsOrder {
                Text(seenRed == nil ? "The first light is now red on your PC. What colour do you see?"
                                    : "Now it's green. What colour do you see?")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                HStack {
                    ForEach([("Red", "r"), ("Green", "g"), ("Blue", "b")], id: \.1) { label, ch in
                        Button(label) { colourSeen(ch) }.buttonStyle(.jcGlass)
                    }
                }
            } else if cal.isSingleLED {
                Text("This connector has one light. Did something light up? Tap it on the model.")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                Text(target.map { $0.part.label } ?? "Tap the part on the model").font(.headline)
                HStack {
                    Button("That's it") { finish() }.buttonStyle(.jcGlass).disabled(target == nil)
                    Button("Nothing lit") { mutate { $0.skipZone() }; target = nil; led = 0; probe(0) }.buttonStyle(.jcGlass)
                }
            } else if phase == .scrub, let range = cal.scrubRange {
                Text("Slide until the light is on the last LED of one fan (or the strip, or the cooler's logo), then tap that part on the model.")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                slider(range)
                Text(target.map { ([$0] + extras).map(name).joined(separator: " · ") } ?? "Tap the part on the model")
                    .font(.headline)
                if target != nil {
                    Text("More than one lit up at once? Tap the others too.").font(.footnote).foregroundStyle(JcTheme.muted)
                }
                Button("It ends here") { phase = .start; probe(cal.cursor) }
                    .buttonStyle(.jcGlass).disabled(target == nil)
            } else if phase == .start, let t = target {
                if t.part == .strip {
                    Text("Which end of the strip is lit?").font(.subheadline).foregroundStyle(JcTheme.muted)
                    HStack {
                        Button("Rear end") { finish(from: "back") }.buttonStyle(.jcGlass)
                        Button("Front end") { finish(from: "front") }.buttonStyle(.jcGlass)
                    }
                } else {
                    Text("One LED is lit: tap exactly where it is on the model.").font(.subheadline).foregroundStyle(JcTheme.muted)
                }
            } else if phase == .direction {
                Text("The light moved one step. Which way?").font(.subheadline).foregroundStyle(JcTheme.muted)
                HStack {
                    Button("Clockwise") { finish(clockwise: true) }.buttonStyle(.jcGlass)
                    Button("Anticlockwise") { finish(clockwise: false) }.buttonStyle(.jcGlass)
                }
            }
        }
    }

    private func slider(_ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(value: $led, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .onChange(of: led) { probe(Int(led)) }
            Text("LED \(Int(led) + 1)").font(.footnote.monospacedDigit()).foregroundStyle(JcTheme.muted)
        }
        .onAppear { led = Double(max(range.lowerBound, min(range.upperBound, Int(led)))) }
    }

    private func start() {
        guard cal == nil else { return }
        let jobs = store.controllers.flatMap { c in
            c.zones.map { PcCalibration.ZoneJob(controller: c.index, zone: $0.index, resizable: $0.resizable ?? false,
                                                 leds: $0.leds, max: $0.max) }
        }
        cal = PcCalibration(zones: jobs)
        if jobs.isEmpty { error = "OpenRGB found no lights — run setup first" } else { probe(0) }
    }

    private func name(_ k: PcLedKey) -> String { k.part.count > 1 ? "\(k.part.label) \(k.index + 1)" : k.part.label }

    private func colourSeen(_ ch: String) {
        if let red = seenRed {
            mutate { $0.setOrder(seenRed: red, seenGreen: ch) }
            seenRed = nil
            probe(cal?.cursor ?? 0)
        } else {
            seenRed = ch
            probe(cal?.cursor ?? 0, color: "#00ff00")
        }
    }

    private func probe(_ k: Int, color: String? = nil) {
        guard let job = cal?.current else { return }
        var args: [String: Any] = ["controller": job.controller, "zone": job.zone, "led": k]
        if let color { args["color"] = color }
        if let resize = cal?.resizeTo { args["resize"] = resize }
        queue.onError = { error = $0 }
        queue.submit(args)
    }

    private func tapped(_ key: PcLedKey) {
        switch phase {
        case .scrub:
            let picked = PcLedKey(part: key.part, index: key.index, led: 0)
            if let t = target, t != picked {
                if let i = extras.firstIndex(of: picked) { extras.remove(at: i) } else { extras.append(picked) }
            } else {
                target = picked
            }
            if cal?.isSingleLED == true { return }
        case .start:
            guard let t = target, key.part == t.part, key.index == t.index else { return }
            let sockets = key.part == .cooler ? PcModel.logoSockets : PcModel.ringSockets
            startDeg = Double(key.led) * 360 / Double(sockets)
            phase = .direction
            if let cal { probe(cal.cursor + 1) }
        case .direction: break
        }
    }

    private func finish(clockwise: Bool? = nil, from: String? = nil) {
        guard let t = target else { return }
        let end = cal?.isSingleLED == true ? (cal?.cursor ?? 0) : Int(led)
        let also = Array(Set(extras.map(\.part)).subtracting([t.part])).sorted { $0.rawValue < $1.rawValue }
        mutate { $0.addSegment(end: end, part: t.part, index: t.index, ringStartDeg: startDeg, clockwise: clockwise,
                               from: from, also: also) }
        target = nil; extras = []; startDeg = nil; phase = .scrub
        led = Double(cal?.cursor ?? 0)
        probe(Int(led))
    }

    private func mutate(_ change: (inout PcCalibration) -> Void) {
        guard var c = cal else { return }
        change(&c)
        cal = c
    }

    private func save(_ cal: PcCalibration) async {
        saving = true
        defer { saving = false }
        if let e = await store.putMap(cal.map()) { error = e; return }
        _ = await store.probe(["clear": true])
        dismiss()
    }
}

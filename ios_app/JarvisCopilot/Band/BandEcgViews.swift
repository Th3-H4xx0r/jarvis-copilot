import SwiftUI

// The ECG screens, after the official app: the live reading (the trace scrolling on ECG paper,
// heart rate, QTc, HRV, progress), each reading's report (rhythm, strip with playback, a Value
// tab of figures against their ranges, an Analysis tab of risk scores), and the list of them.

private let ecgRed = Color(red: 0.93, green: 0.27, blue: 0.24)

/// ECG paper: 1 mm squares under 5 mm ones, the trace drawn over them. `seconds` of trace fill
/// the width (25 mm/s: a 5 mm square is 0.2 s).
struct BandEcgStrip: View {
    let trace: [Double]
    let rate: Int
    var seconds: Double = 3
    /// Where the visible window ends in the trace (nil: its end).
    var end: Int?
    var ink: Color = ecgRed
    var paper: Color = Color.white.opacity(0.06)
    var showsSeconds = false

    var body: some View {
        Canvas { context, size in
            let perSecond = size.width / seconds
            let major = perSecond / 5, minor = major / 5
            var fine = Path(), bold = Path()
            func rule(_ from: CGPoint, _ to: CGPoint, major: Bool) {
                if major { bold.move(to: from); bold.addLine(to: to) } else { fine.move(to: from); fine.addLine(to: to) }
            }
            var x: CGFloat = 0
            var i = 0
            while x <= size.width {
                rule(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height), major: i % 5 == 0)
                x += minor; i += 1
            }
            // From the middle out, so the baseline sits on a bold line.
            var y: CGFloat = size.height / 2
            i = 0
            while y <= size.height {
                rule(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y), major: i % 5 == 0)
                y += minor; i += 1
            }
            y = size.height / 2 - minor; i = 1
            while y >= 0 {
                rule(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y), major: i % 5 == 0)
                y -= minor; i += 1
            }
            context.stroke(fine, with: .color(paper), lineWidth: 0.5)
            context.stroke(bold, with: .color(paper.opacity(2.2)), lineWidth: 0.8)

            let count = Int(seconds * Double(rate))
            let last = min(trace.count, end ?? trace.count)
            let first = max(0, last - count)
            guard last - first > 1 else {
                // Nothing yet: the flat line a lead draws before the heart shows.
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                               with: .color(ink.opacity(0.5)), lineWidth: 1.5)
                return
            }
            let window = Array(trace[first..<last])
            let spread = BandEcgSignal.spread(window)
            let mid = window.sorted()[window.count / 2]
            // Steady beats at a readable height, but never a peak off the paper.
            let reach = max(1, window.map { abs($0 - mid) }.max() ?? 1)
            let scale = min(size.height * 0.36 / spread, size.height * 0.46 / reach)
            var line = Path()
            for (k, v) in window.enumerated() {
                let point = CGPoint(x: CGFloat(k) / CGFloat(rate) * perSecond,
                                    y: size.height / 2 - CGFloat(v - mid) * scale)
                if k == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            if showsSeconds {
                for s in 0...Int(seconds) {
                    context.draw(Text("\(Int(Double(first) / Double(rate)) + s)s").font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: CGFloat(s) * perSecond + 10, y: size.height - 8))
                }
            }
        }
        .accessibilityLabel("ECG trace")
    }
}

// MARK: Live

/// The reading as it runs: full screen, black, the trace scrolling right to left.
struct BandEcgLiveView: View {
    @ObservedObject var session: BandSession
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button(action: close) { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop the ECG")
                    Spacer()
                    Text("ECG").font(.headline)
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
                .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(heartRate.map(String.init) ?? "--")
                            .font(.system(size: 76, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 0) {
                            Image(systemName: "heart.fill").foregroundStyle(ecgRed)
                                .symbolEffect(.pulse, options: .repeating)
                            Text("bpm").font(.title3.weight(.semibold))
                        }
                    }
                    HStack(spacing: 24) {
                        Text("QTc \(qtc.map(String.init) ?? "--")")
                        Text("HRV \(hrv.map(String.init) ?? "--")")
                    }
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                }
                .padding(.horizontal, 24)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    BandEcgStrip(trace: BandEcgSignal.cleaned(Array(session.ecgSamples.suffix(session.ecgSampleRate * 6)),
                                                              rate: session.ecgSampleRate),
                                 rate: session.ecgSampleRate, seconds: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                Text("25 mm/s · \(session.ecgSampleRate) Hz")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 24)
                Text(hint).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 24)
                Spacer()
                HStack {
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 10)
                        Circle().trim(from: 0, to: Double(progress) / 100)
                            .stroke(ecgRed, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.snappy, value: progress)
                        Text("\(progress)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 70, height: 70)
                    Spacer()
                }
                .padding(.bottom, 30)
            }
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var reading: BandReading? { session.lastReading?.measure == .ecg ? session.lastReading : nil }
    private var heartRate: Int? { reading?.heartRate ?? session.ecgHeartRates.last }
    private var hrv: Int? { reading?.hrv }
    private var qtc: Int? { reading?.ecg.map(\.qtcMs).flatMap { $0 > 0 ? $0 : nil } }
    private var progress: Int { reading?.progress ?? 0 }
    private var hint: String {
        if reading?.leadOff == true || session.ecgSamples.isEmpty { return "Rest your arm and hold a finger on the band's metal top." }
        return "Keep still and keep your finger on the band until the reading ends."
    }
}

// MARK: Report

/// One reading's report: the strip, then Value and Analysis.
struct BandEcgReportView: View {
    let report: BandEcgReport
    @State private var tab: Int

    init(report: BandEcgReport, initialTab: Int = 0) {
        self.report = report
        _tab = State(initialValue: initialTab)
    }

    @State private var playing = false
    @State private var playhead: Double = 0
    @State private var started = Date()

    private var trace: [Double] { BandEcgSignal.cleaned(report.samples, rate: report.sampleRate) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(report.diagnosis?.rhythm ?? "ECG").font(.headline).padding(.horizontal, 20)
                strip
                Picker("", selection: $tab) {
                    Text("Value").tag(0)
                    Text("Analysis").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                if tab == 0 { valueTab } else { analysisTab }
                Text("A wrist-band ECG is a wellness estimate, not a medical diagnosis. If you feel unwell, see a doctor.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 24)
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(report.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }

    // The trace, with playback: the window walks through the reading.
    private var strip: some View {
        VStack(spacing: 10) {
            if report.samples.isEmpty {
                BandEcgStrip(trace: [], rate: max(1, report.sampleRate), seconds: 3)
                    .frame(height: 180)
                Text("No waveform was kept for this reading.").font(.caption).foregroundStyle(.secondary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
                    BandEcgStrip(trace: trace, rate: report.sampleRate, seconds: 3, end: endIndex(context.date),
                                 showsSeconds: true)
                }
                .frame(height: 180)
                HStack(spacing: 14) {
                    Button { togglePlay() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    Button { playing = false; playhead = 0 } label: { Image(systemName: "stop.fill") }
                    ProgressView(value: min(1, playhead / max(1, report.duration)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            }
        }
    }

    private func togglePlay() {
        if playing {
            playhead = Date().timeIntervalSince(started)
            playing = false
            return
        }
        if playhead >= report.duration { playhead = 0 }
        started = Date().addingTimeInterval(-playhead)
        playing = true
    }

    private func endIndex(_ now: Date) -> Int {
        let window = 3.0
        let t = playing ? min(report.duration, now.timeIntervalSince(started)) : playhead
        if playing, t >= report.duration { DispatchQueue.main.async { playing = false; playhead = report.duration } }
        return Int(max(window, t) * Double(report.sampleRate))
    }

    // MARK: Value

    private var valueTab: some View {
        VStack(spacing: 16) {
            CardGroup("Heart rate") {
                VStack(spacing: 14) {
                    HStack {
                        figure(report.averageHeartRate.map { "\($0) bpm" }, "Avg. HR")
                        figure(report.maxHeartRate.map { "\($0) bpm" }, "Max. HR")
                        figure(report.minHeartRate.map { "\($0) bpm" }, "Min. HR")
                    }
                    let shares = report.heartRateShares
                    HStack {
                        figure(percent(shares.normal), "Normal\n(60–100 bpm)")
                        figure(percent(shares.fast), "Fast\n(>100 bpm)")
                        figure(percent(shares.slow), "Slow\n(<60 bpm)")
                    }
                }
                .padding(16)
            }
            if let d = report.diagnosis {
                CardGroup("HRV") {
                    rangeRow("HRV", Double(d.hrv), "0 – 210 ms", 0...210)
                    RowDivider()
                    rangeRow("SDNN", Double(d.sdnnMs), "102 – 180 ms", 102...180)
                    RowDivider()
                    rangeRow("RMSSD", Double(d.rmssdMs), "15 – 39 ms", 15...39)
                }
                CardGroup("ECG") {
                    rangeRow("QTc", Double(d.qtcMs), "260 – 440 ms", 260...440)
                    RowDivider()
                    rangeRow("QRS amplitude", Double(d.qrsAmplitudeUv) / 1000, "0.05 – 1.5 mV", 0.05...1.5, format: "%.2f")
                    RowDivider()
                    rangeRow("QRS duration", Double(d.qrsMs), "80 – 120 ms", 80...120)
                    RowDivider()
                    Row {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("QRS direction")
                                Text("Upward, downward").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(d.qrsDirection)
                        }
                    }
                    RowDivider()
                    rangeRow("ST amplitude", Double(d.stAmplitudeUv) / 1000, "−0.05 – 0.1 mV", -0.05...0.1, format: "%.2f")
                }
            }
        }
    }

    private func figure(_ value: String?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "—").font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    /// A figure with its range under its name, and ↑ / ↓ when it falls outside it.
    private func rangeRow(_ name: String, _ value: Double, _ range: String, _ normal: ClosedRange<Double>,
                          format: String = "%.0f") -> some View {
        Row {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(range).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: format, value)).monospacedDigit()
                if value > normal.upperBound {
                    Image(systemName: "arrow.up").foregroundStyle(JcTheme.amber)
                } else if value < normal.lowerBound {
                    Image(systemName: "arrow.down").foregroundStyle(JcTheme.blue)
                }
            }
        }
    }

    // MARK: Analysis

    private var analysisTab: some View {
        VStack(spacing: 16) {
            if let d = report.diagnosis {
                CardGroup {
                    BandEcgRadar(values: risks(d).map { ($0.short, $0.score) })
                        .frame(height: 260)
                        .padding(12)
                }
                ForEach(risks(d), id: \.title) { risk in riskCard(risk) }
                CardGroup("Arrhythmia", footer: "No/Low · Moderate · High, as the band graded each.") {
                    ForEach(Array(d.allFindings.enumerated()), id: \.offset) { index, finding in
                        if index > 0 { RowDivider() }
                        Row {
                            HStack {
                                Text(finding.name)
                                Spacer()
                                Capsule()
                                    .fill(gradeColor(finding.grade).opacity(0.25))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(gradeColor(finding.grade))
                                            .frame(width: 26 + CGFloat(finding.grade) * 22)
                                    }
                                    .frame(width: 100, height: 8)
                            }
                        }
                    }
                }
            } else {
                Text("The band didn't send its analysis for this reading.").foregroundStyle(.secondary).padding()
            }
        }
    }

    private struct Risk { let title: String; let short: String; let score: Int; let text: String; let basis: String }

    private func risks(_ d: BandEcgDiagnosis) -> [Risk] {
        func level(_ s: Int) -> Int { s < 30 ? 0 : s < 60 ? 1 : 2 }
        func plain(_ s: Int, _ what: String) -> String {
            switch level(s) {
            case 0: return "This test shows a normal ECG signal and a low risk of \(what) in the near future."
            case 1: return "This test shows some signs worth watching and a moderate risk of \(what). Repeat the test when rested."
            default: return "This test shows a higher risk of \(what). If it repeats or you feel unwell, talk to a doctor."
            }
        }
        let stress = level(d.stressIndex) == 0 ? "This test shows you are under mild stress. Appropriate stress can improve your potential and efficiency."
            : level(d.stressIndex) == 1 ? "This test shows moderate stress. Take a few slow breaths and short breaks."
            : "This test shows high stress. Rest, slow breathing and sleep help most."
        let fatigue = level(d.fatigueIndex) == 0 ? "This test shows you are well rested."
            : level(d.fatigueIndex) == 1 ? "This test shows a poor condition. You may feel slightly fatigued, but it will not affect your daily activities. Maintain regular rests, get enough sleep and exercise as appropriate."
            : "This test shows you are quite fatigued. Rest and sleep before demanding activity."
        return [
            Risk(title: "Myocarditis risk", short: "Myocard. risk", score: d.myocarditisRisk,
                 text: plain(d.myocarditisRisk, "developing myocarditis"),
                 basis: "Based on ST amplitude, QRS amplitude, QTc, heart rate and risk of block-related arrhythmias."),
            Risk(title: "Fatigue index", short: "Fatigue", score: d.fatigueIndex, text: fatigue, basis: "Based on SDNN and RMSSD."),
            Risk(title: "Mental stress index", short: "Mental stress", score: d.stressIndex, text: stress,
                 basis: "Based on SDNN and RMSSD."),
            Risk(title: "Arteriosclerosis risk", short: "Arte. scle.", score: d.arteriosclerosisRisk,
                 text: plain(d.arteriosclerosisRisk, "developing arteriosclerosis"),
                 basis: "Based on PWV, heart rate and risk of block-related arrhythmias."),
            Risk(title: "Coronary artery disease risk", short: "Cor. arte. dis.", score: d.coronaryRisk,
                 text: plain(d.coronaryRisk, "developing coronary artery disease"),
                 basis: "Based on PWV, heart rate and risk of myocardial-ischemia-related arrhythmias."),
            Risk(title: "Cardiac arrhythmia risk", short: "Arrhythmia", score: d.arrhythmiaRisk,
                 text: d.arrhythmiaRisk < 30 ? "This test shows a stable heart rhythm and emotional stability. Maintain your lifestyle."
                     : plain(d.arrhythmiaRisk, "arrhythmia"),
                 basis: "Based on SDNN, RMSSD and risk of various arrhythmias."),
        ]
    }

    private func riskCard(_ risk: Risk) -> some View {
        CardGroup(risk.title) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(risk.score)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(gradeColor(risk.score < 30 ? 1 : risk.score < 60 ? 2 : 3))
                            .frame(width: max(10, geo.size.width * CGFloat(min(100, risk.score)) / 100))
                    }
                }
                .frame(height: 10)
                HStack {
                    Text("0"); Spacer(); Text("Reference"); Spacer(); Text("50"); Spacer(); Text("100")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text(risk.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(risk.basis).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private func gradeColor(_ grade: Int) -> Color {
        grade >= 3 ? .orange : grade == 2 ? JcTheme.amber : JcTheme.success
    }
}

/// The six scores on a hexagon (0 at the middle, 100 at the rim).
struct BandEcgRadar: View {
    let values: [(String, Int)]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 34
            let n = max(3, values.count)
            func point(_ i: Int, _ r: CGFloat) -> CGPoint {
                let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(n)
                return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            }
            for ring in 1...3 {
                var hex = Path()
                for i in 0..<n {
                    let p = point(i, radius * CGFloat(ring) / 3)
                    if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
                }
                hex.closeSubpath()
                context.fill(hex, with: .color(ecgRed.opacity(0.05)))
                context.stroke(hex, with: .color(ecgRed.opacity(0.3)), lineWidth: 1)
            }
            var shape = Path()
            for (i, v) in values.enumerated() {
                let p = point(i, radius * CGFloat(max(2, min(100, v.1))) / 100)
                if i == 0 { shape.move(to: p) } else { shape.addLine(to: p) }
            }
            shape.closeSubpath()
            context.fill(shape, with: .color(ecgRed.opacity(0.35)))
            context.stroke(shape, with: .color(ecgRed), lineWidth: 2)
            for (i, v) in values.enumerated() {
                context.draw(Text(v.0).font(.caption2).foregroundStyle(.secondary), at: point(i, radius + 20))
            }
        }
        .accessibilityLabel(values.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
}

// MARK: History

/// A band's ECG readings, newest first; each opens its report.
struct BandEcgHistoryView: View {
    let deviceID: String
    @State private var reports: [BandEcgReport] = []

    var body: some View {
        ScrollView {
            if reports.isEmpty {
                Text("No ECG readings yet. Take one from the band's page: rest your arm and hold a finger on its metal top.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(24)
            } else {
                CardGroup {
                    ForEach(Array(reports.enumerated()), id: \.offset) { index, report in
                        if index > 0 { RowDivider() }
                        NavigationLink { BandEcgReportView(report: report) } label: {
                            Row(minHeight: 58) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(report.diagnosis?.rhythm ?? "ECG").font(.body.weight(.medium))
                                        Text(report.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let hr = report.averageHeartRate { Text("\(hr) bpm").monospacedDigit() }
                                    JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("ECG reports")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reports = BandEcgStore.reports(deviceID: deviceID) }
    }
}

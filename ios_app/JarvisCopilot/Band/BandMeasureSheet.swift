import SwiftUI

/// One reading from the band's page, start to finish: the sheet's mode, the reading running
/// (through `BandWearAsk`, so "not worn" still asks for the band), and how it ended.
@MainActor
final class BandMeasureFlow: ObservableObject {
    /// The reading the sheet is up for.
    @Published var type: BandMeasure?
    @Published private(set) var mode: BandMeasureMode = .general
    @Published private(set) var running = false
    /// The finished reading, as its mode has it.
    @Published private(set) var result: BandReading?
    @Published private(set) var failure: String?
    /// The phone-side calibration the result was moved by, to get the band's own number back.
    private var resultShift: Double = 0
    private var run: Task<Void, Never>?

    let session: BandSession
    let ask: BandWearAsk

    init(session: BandSession, ask: BandWearAsk) {
        self.session = session
        self.ask = ask
    }

    /// Puts the sheet up and starts `type` in the mode picked last for it.
    func start(_ type: BandMeasure) {
        self.type = type
        mode = BandMeasureMode.saved(for: type)
        begin()
    }

    /// A new mode is remembered for next time and, with a reading up, takes it again.
    func setMode(_ mode: BandMeasureMode) {
        guard let type, mode != self.mode else { return }
        BandMeasureMode.save(mode, for: type)
        self.mode = mode
        if running || result != nil || failure != nil { begin() }
    }

    /// Takes the reading (again).
    func begin() {
        guard let type else { return }
        halt()
        result = nil
        failure = nil
        running = true
        resultShift = mode == .private ? BandReferenceCalibration.saved(for: type)?.offset ?? 0 : 0
        run = Task { [weak self] in
            guard let self else { return }
            // A reading cancelled a moment ago is still telling the band to stop.
            for _ in 0..<30 where self.session.measuring != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            do {
                try await self.ask.measure(type)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.running = false
                self.failure = error.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            self.running = false
            if let r = self.session.lastReading, r.measure == type, r.finished, r.valueText != nil {
                self.result = r
            } else {
                let r = self.session.lastReading
                self.failure = r?.failure ?? (r?.notWorn == true ? BandReading.Reason.notWorn : BandReading.Reason.noReading)
            }
        }
    }

    /// Stops the reading in flight and leaves the sheet up, ready (calibrating mid-reading
    /// would spoil it anyway).
    func pause() {
        halt()
        result = nil
        failure = nil
    }

    /// Cancel, a swipe down or leaving the page: the reading stops and the sheet goes.
    func cancel() {
        halt()
        type = nil
    }

    private func halt() {
        run?.cancel()
        run = nil
        ask.dismiss()
        running = false
    }

    /// The band's own number behind the result (before any phone-side calibration).
    var bandValue: Double? { result?.referenceValue.map { $0 - resultShift } }

    /// Keeps `reference` (a real device's reading, °C for temperature) against the band's
    /// number: Private readings move by the difference from now on, this one included.
    func calibrate(reference: Double) {
        guard let type, let band = bandValue else { return }
        let c = BandReferenceCalibration(reference: reference, band: band, date: Date())
        BandReferenceCalibration.save(c, for: type)
        result = result?.shifted(by: c.offset - resultShift)
        resultShift = c.offset
        BandMeasureMode.save(.private, for: type)
        mode = .private
    }

    /// Back to the band's numbers alone for `type`.
    func removeCalibration() {
        guard let type else { return }
        BandReferenceCalibration.save(nil, for: type)
        if mode == .private, result != nil {
            result = result?.shifted(by: -resultShift)
            resultShift = 0
        }
    }

    /// Holds the sheet in one state, for the render harness.
    func pin(type: BandMeasure, mode: BandMeasureMode, running: Bool = false, result: BandReading? = nil, failure: String? = nil) {
        self.type = type
        self.mode = mode
        self.running = running
        self.result = result
        self.failure = failure
    }

    /// The sheet's binding: a swipe down is Cancel.
    var sheet: Binding<BandMeasure?> {
        Binding(get: { [weak self] in self?.type },
                set: { [weak self] value in if value == nil, self?.type != nil { self?.cancel() } })
    }
}

/// The bottom sheet a reading runs in: the General/Private switch, what Private is calibrated
/// to, a breathing gauge with "Measuring" big under it, then the number big as it comes in —
/// Cancel along the bottom.
struct BandMeasureSheet: View {
    let type: BandMeasure
    @ObservedObject var flow: BandMeasureFlow
    @ObservedObject var session: BandSession
    /// The band-side calibration editors, which live in the band's settings.
    let onEditBandCalibration: () -> Void

    @State private var calibrating = false
    @State private var reference: Double = 0

    static let height: CGFloat = 590

    var body: some View {
        VStack(spacing: 0) {
            header
            if calibrating {
                calibrationPanel
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                gauge
                    .padding(.top, 22)
                readout
                    .padding(.top, 18)
                Spacer(minLength: 8)
                buttons
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RingWearPrompt.sheetBackground)
        .animation(.snappy(duration: 0.3), value: calibrating)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            Text(type.label)
                .font(.title3.weight(.semibold))
                .padding(.top, 22)
            if type.hasModes {
                BandModeSwitch(mode: Binding(get: { flow.mode }, set: { flow.setMode($0) }))
                    .disabled(calibrating)
                calibrationLine
            }
        }
    }

    /// What Private means for this reading right now, with a way to set it.
    @ViewBuilder private var calibrationLine: some View {
        HStack(spacing: 6) {
            Image(systemName: flow.mode == .private ? (calibrated ? "checkmark.seal.fill" : "exclamationmark.circle") : "person.3.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(flow.mode == .private ? (calibrated ? JcTheme.accent : .orange) : JcTheme.muted)
            Text(calibrationText)
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if flow.mode == .private, let action = calibrationAction {
                Button(action.title, action: action.run)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(JcTheme.accent)
                    .buttonStyle(.plain)
            }
        }
        .frame(height: 18)
    }

    private var calibrated: Bool {
        switch type {
        case .bloodPressure: return session.bpCalibration?.enabled == true
        case .bloodGlucose: return session.glucoseCalibration?.enabled == true
        case .bloodComponent: return session.componentCalibration?.enabled == true
        default: return BandReferenceCalibration.saved(for: type) != nil
        }
    }

    private var calibrationText: String {
        guard flow.mode == .private else { return "The band's standard estimate" }
        switch type {
        case .bloodPressure:
            if let c = session.bpCalibration, c.enabled { return "Calibrated to your cuff · \(c.systolic)/\(c.diastolic)" }
            return "Not calibrated to a cuff yet"
        case .bloodGlucose: return calibrated ? "Calibrated to your meter readings" : "Not calibrated to a meter yet"
        case .bloodComponent: return calibrated ? "Calibrated to your lab results" : "Not calibrated to a lab test yet"
        default:
            guard let c = BandReferenceCalibration.saved(for: type) else {
                return flow.result == nil ? "Measure next to \(type.referenceDevice)" : "Not calibrated yet"
            }
            return "Calibrated \(c.date.formatted(.relative(presentation: .named))) · \(offsetText(c.offset))"
        }
    }

    private var calibrationAction: (title: String, run: () -> Void)? {
        if type.hasPrivateMode {
            return (calibrated ? "Edit" : "Set up", {
                flow.pause()
                onEditBandCalibration()
            })
        }
        // The phone's calibration needs the band's number to compare with.
        guard flow.bandValue != nil else { return nil }
        return (calibrated ? "Recalibrate" : "Calibrate", openCalibration)
    }

    private func offsetText(_ d: Double) -> String {
        let sign = d >= 0 ? "+" : "−"
        let unit = type == .temperature ? TemperatureUnit.current.label : type.referenceUnit
        let size = type == .temperature && TemperatureUnit.current == .fahrenheit ? abs(d) * 9 / 5 : abs(d)
        let number = type == .temperature || type == .bodyComposition ? String(format: "%.1f", size) : String(Int(size.rounded()))
        return "\(sign)\(number)\(unit.hasPrefix("%") || unit.hasPrefix("°") ? "" : " ")\(unit)"
    }

    // MARK: Gauge

    private var live: BandReading? {
        guard flow.running, let r = session.lastReading, r.measure == type, session.measuring == type else { return nil }
        return r
    }

    private var progress: Double? {
        if flow.result != nil { return 1 }
        return live?.progress.flatMap { $0 > 0 ? min(1, Double($0) / 100) : nil }
    }

    private var gauge: some View {
        ZStack {
            if flow.running {
                BandMeasureRipples(tint: type.tint)
            }
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 8)
                .frame(width: 132, height: 132)
            if let progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AngularGradient(colors: [type.tint.opacity(0.55), type.tint, JcTheme.accent], center: .center),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 132, height: 132)
                    .animation(.easeOut(duration: 0.6), value: progress)
            } else if flow.running {
                BandMeasureSpinner(tint: type.tint)
                    .frame(width: 132, height: 132)
            }
            Circle()
                .fill(RadialGradient(colors: [type.tint.opacity(0.28), type.tint.opacity(0.04)],
                                     center: .center, startRadius: 4, endRadius: 58))
                .frame(width: 104, height: 104)
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(symbolTint)
                .symbolEffect(.pulse, isActive: flow.running)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 190, height: 190)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if flow.result != nil { return "checkmark" }
        if flow.failure != nil { return "exclamationmark" }
        return type.icon
    }

    private var symbolTint: Color {
        if flow.result != nil { return JcTheme.accent }
        if flow.failure != nil { return .orange }
        return type.tint
    }

    // MARK: Readout

    @ViewBuilder private var readout: some View {
        VStack(spacing: 6) {
            if let r = flow.result ?? live, let big = r.bigValue {
                Text(big.value)
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: big.value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(unitLine(big.unit))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(JcTheme.muted)
            } else if let failure = flow.failure {
                Text("No reading")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if flow.running {
                BandMeasuringTitle()
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Ready")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Measure when you're set.")
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .frame(minHeight: 96, alignment: .top)
        .padding(.horizontal, 12)
    }

    private func unitLine(_ unit: String) -> String {
        var parts = [String]()
        if !unit.isEmpty { parts.append(unit) }
        if flow.result != nil, type.hasModes { parts.append(flow.mode.label) }
        else if let p = live?.progress, p > 0, p < 100 { parts.append("\(p)%") }
        return parts.joined(separator: " · ")
    }

    private var hint: String {
        switch type {
        case .bloodPressure: return "Sit still with your arm relaxed at heart level."
        case .ecg, .bodyComposition: return "Keep a finger on the band's metal top."
        case .bloodGlucose, .bloodComponent: return "Keep still — this takes about a minute."
        default: return "Keep still and breathe normally."
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            if flow.failure != nil || (!flow.running && flow.result == nil) {
                primary(flow.failure != nil ? "Try Again" : "Measure", icon: "play.fill") { flow.begin() }
            } else if flow.result != nil {
                primary("Measure Again", icon: "arrow.clockwise") { flow.begin() }
            }
            Button { flow.cancel() } label: {
                Text(flow.running ? "Cancel" : "Done")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .jcLiquidGlass(in: Capsule(), tint: .clear)
            }
            .buttonStyle(.plain)
        }
    }

    private func primary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: [JcTheme.primaryBlueHi, JcTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: JcTheme.accent.opacity(0.35), radius: 14, y: 4)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Phone-side calibration

    private func openCalibration() {
        guard let band = flow.bandValue else { return }
        // Start from what the band read, in the unit it is typed in.
        let shown = type == .temperature ? TemperatureUnit.current.value(band) : band
        reference = step < 1 ? (shown * 10).rounded() / 10 : shown.rounded()
        calibrating = true
    }

    private var step: Double { type == .temperature || type == .bodyComposition ? 0.1 : 1 }

    private var referenceText: String {
        step < 1 ? String(format: "%.1f", reference) : String(Int(reference))
    }

    private var bandText: String {
        guard let band = flow.bandValue else { return "—" }
        if type == .temperature { return TemperatureUnit.current.format(band) }
        let unit = type.referenceUnit
        let n = step < 1 ? String(format: "%.1f", band) : String(Int(band.rounded()))
        return unit.isEmpty ? n : (unit.hasPrefix("%") ? n + unit : "\(n) \(unit)")
    }

    private var calibrationPanel: some View {
        VStack(spacing: 0) {
            Text("What did \(type.referenceDevice) read just now?")
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 26)
            HStack(spacing: 22) {
                stepButton("minus") { reference -= step }
                VStack(spacing: 2) {
                    Text(referenceText)
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: reference)
                        .frame(minWidth: 130)
                    Text(type == .temperature ? TemperatureUnit.current.label : (type.referenceUnit.isEmpty ? "score" : type.referenceUnit))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(JcTheme.muted)
                }
                stepButton("plus") { reference += step }
            }
            .padding(.top, 22)
            Text("The band read \(bandText). Private readings will move by the difference.")
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            if BandReferenceCalibration.saved(for: type) != nil {
                Button("Remove calibration") {
                    flow.removeCalibration()
                    calibrating = false
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            Spacer(minLength: 8)
            VStack(spacing: 10) {
                primary("Save Calibration", icon: "checkmark.seal.fill") {
                    let typed = type == .temperature && TemperatureUnit.current == .fahrenheit ? (reference - 32) * 5 / 9 : reference
                    flow.calibrate(reference: typed)
                    calibrating = false
                }
                Button { calibrating = false } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .jcLiquidGlass(in: Capsule(), tint: .clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .jcLiquidGlass(in: Circle(), tint: .clear)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// The measure sheet as the band's page shows it: "Put the band on" while the band says it
/// isn't worn, and the band-side calibration editors over it.
struct BandMeasureSheetHost: View {
    let type: BandMeasure
    @ObservedObject var flow: BandMeasureFlow
    @ObservedObject var ask: BandWearAsk
    @State private var editing = false

    private var asking: Bool { ask.prompt == type }

    var body: some View {
        Group {
            if asking {
                RingWearPrompt(metric: type.label, kind: .band) { flow.cancel() }
            } else {
                BandMeasureSheet(type: type, flow: flow, session: flow.session) { editing = true }
            }
        }
        .presentationDetents([.height(asking ? 430 : BandMeasureSheet.height)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(RingWearPrompt.sheetBackground)
        .presentationCornerRadius(34)
        .sheet(isPresented: $editing) {
            NavigationStack {
                switch type {
                case .bloodPressure: BandBPCalibrationEditor(session: flow.session)
                case .bloodGlucose: BandGlucoseCalibrationEditor(session: flow.session)
                default: BandComponentCalibrationEditor(session: flow.session)
                }
            }
        }
    }
}

/// General | Private, as a sliding pill.
struct BandModeSwitch: View {
    @Binding var mode: BandMeasureMode
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BandMeasureMode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.snappy(duration: 0.28)) { mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m == .general ? "person.3.fill" : "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(m.label).font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(mode == m ? Color.black : JcTheme.muted)
                    .frame(width: 112, height: 36)
                    .background {
                        if mode == m {
                            Capsule()
                                .fill(LinearGradient(colors: [JcTheme.primaryBlueHi, JcTheme.accent], startPoint: .leading, endPoint: .trailing))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(JcTheme.glassBorder, lineWidth: 1))
    }
}

/// Rings of the reading's colour leaving the gauge, one after another.
private struct BandMeasureRipples: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(tint.opacity(0.4 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: 132, height: 132)
                        .scaleEffect(1 + phase * 0.42)
                }
            }
        }
    }
}

/// An arc going round while there's no progress to show.
private struct BandMeasureSpinner: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(AngularGradient(colors: [tint.opacity(0), tint], center: .center, startAngle: .zero, endAngle: .degrees(100)),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees((t * 220).truncatingRemainder(dividingBy: 360)))
        }
    }
}

/// "Measuring" with its dots filling in.
private struct BandMeasuringTitle: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 4
            Text("Measuring" + String(repeating: ".", count: dots))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                // The dots grow without moving the word.
                .frame(width: 230, alignment: .leading)
                .padding(.leading, 34)
        }
    }
}

extension BandReading {
    /// The number for the sheet, big, and what goes under it.
    var bigValue: (value: String, unit: String)? {
        func split(_ s: String) -> (String, String) {
            guard let space = s.firstIndex(of: " ") else { return (s, "") }
            return (String(s[..<space]), String(s[s.index(after: space)...]))
        }
        if let s = systolic, let d = diastolic { return ("\(s)/\(d)", "mmHg") }
        if let g = bloodGlucose { return split(GlucoseUnit.current.format(g)) }
        if let c = bloodComponent {
            let (v, u) = split(UricAcidUnit.current.format(c.uricAcid))
            return (v, "\(u) uric acid")
        }
        if let b = bodyComposition { return (String(format: "%.1f%%", b.bodyFatPercent), String(format: "body fat · BMI %.1f", b.bmi)) }
        if let t = temperatureC { return (String(format: "%.1f", TemperatureUnit.current.value(t)), TemperatureUnit.current.label) }
        if let o = spo2 { return ("\(o)%", "blood oxygen") }
        if let v = stress { return ("\(v)", "stress") }
        if let hr = heartRate { return ("\(hr)", "bpm") }
        return nil
    }

    /// The phone-calibrated number moved by `d` more.
    func shifted(by d: Double) -> BandReading {
        calibrated(by: BandReferenceCalibration(reference: d, band: 0, date: date))
    }
}

import Foundation

/// One frame on the wire, as the transport saw it.
struct RingFrame: Equatable {
    let outbound: Bool
    let channel: RingChannel
    let cmd: UInt8
    let payload: [UInt8]
    var isError = false
    var note = ""
}

/// A frame with its meaning worked out, for the log the user reads.
struct RingLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let frame: RingFrame
    /// What the frame does, e.g. "Set heart-rate monitoring".
    let title: String
    /// The values it carries, e.g. "on, every 10 min".
    let detail: String

    var hex: String {
        let bytes = [frame.cmd] + frame.payload
        return Data(bytes.prefix(20)).hexString + (bytes.count > 20 ? "…" : "")
    }
}

/// The ring's command and gesture log — what was sent, what came back, and every
/// input and event the ring pushed. Its own object, so a busy link redraws the
/// log and not every ring screen.
@MainActor
final class RingLog: ObservableObject {
    @Published private(set) var entries: [RingLogEntry] = []
    private let limit = 400

    func record(_ frame: RingFrame, at date: Date = Date()) {
        let described = RingLogDecoder.describe(frame)
        entries.insert(RingLogEntry(date: date, frame: frame, title: described.title, detail: described.detail), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// A line the log should carry that isn't a frame — what an input ran, say.
    func note(_ title: String, _ detail: String, at date: Date = Date()) {
        let frame = RingFrame(outbound: false, channel: .command, cmd: 0, payload: [], note: "")
        entries.insert(RingLogEntry(date: date, frame: frame, title: title, detail: detail), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}

/// Turns a ring frame into plain words. Pure, so the log can be tested without a ring.
enum RingLogDecoder {

    static func describe(_ frame: RingFrame) -> (title: String, detail: String) {
        var described = frame.channel == .bigData ? bigData(frame) : command(frame)
        if frame.isError { described.detail = join("the ring rejected it", described.detail) }
        if !frame.note.isEmpty { described.detail = join(described.detail, frame.note) }
        return described
    }

    // MARK: Command channel

    private static func command(_ frame: RingFrame) -> (title: String, detail: String) {
        let p = frame.payload
        let out = frame.outbound
        switch frame.cmd {
        case RingOp.setTime:
            return out ? ("Set the ring's clock", clock(p))
                       : ("Ring capabilities (block A)", "\(p.count) bytes of feature flags")
        case RingOp.accelerometer:
            guard !out, let a = RingDecode.accelerometer(p) else { return ("Read accelerometer", "") }
            return ("Accelerometer", String(format: "x %d  y %d  z %d  (%.2f g)", a.x, a.y, a.z, a.magnitudeG))
        case RingOp.battery:
            guard !out, let battery = RingDecode.battery(p) else { return ("Read battery", "") }
            return ("Battery", "\(battery.percent)%" + (battery.charging ? ", charging" : ""))
        case RingOp.deviceSupport:
            return out ? ("Read capabilities", "") : ("Ring capabilities (block B)", "\(p.count) bytes of feature flags")
        case RingOp.heartRateMonitor:
            if out, at(p, 0) == 2 {
                return ("Set heart-rate monitoring", join(onOff(at(p, 1) == 1), every(at(p, 2))))
            }
            if !out, let m = RingDecode.heartRateMonitor(p) {
                return ("Heart-rate monitoring", join(onOff(m.enabled), every(m.intervalMinutes)))
            }
            return (out ? "Read heart-rate monitoring" : "Heart-rate monitoring", ack(p, out))
        case RingOp.spo2Monitor:
            if out, at(p, 0) == 2 { return ("Set SpO₂ monitoring", onOff(at(p, 1) == 1)) }
            if !out, let m = RingDecode.spo2Monitor(p) { return ("SpO₂ monitoring", onOff(m.enabled)) }
            return (out ? "Read SpO₂ monitoring" : "SpO₂ monitoring", ack(p, out))
        case RingOp.stressMonitor:
            if out, at(p, 0) == 2 { return ("Set stress monitoring", onOff(at(p, 1) == 1)) }
            if !out, let m = RingDecode.stressMonitor(p) { return ("Stress monitoring", onOff(m.enabled)) }
            return (out ? "Read stress monitoring" : "Stress monitoring", ack(p, out))
        case RingOp.hrvMonitor:
            if out, at(p, 0) == 2 { return ("Set HRV monitoring", join(onOff(at(p, 1) == 1), every(at(p, 3)))) }
            if !out, let m = RingDecode.hrvMonitor(p) {
                return ("HRV monitoring", join(onOff(m.enabled), every(m.intervalMinutes)))
            }
            return (out ? "Read HRV monitoring" : "HRV monitoring", ack(p, out))
        case RingOp.temperatureMonitor:
            if out, at(p, 1) == 2 { return ("Set temperature monitoring", join(onOff(at(p, 2) == 1), every(at(p, 3)))) }
            if !out, let m = RingDecode.temperatureMonitor(p) {
                return ("Temperature monitoring", join(onOff(m.enabled), every(m.intervalMinutes)))
            }
            return (out ? "Read temperature monitoring" : "Temperature monitoring", ack(p, out))
        case RingOp.touch:
            let control = at(p, 1) == 1 ? "gesture" : "touch"
            if out, at(p, 0) == 2 { return ("Set \(control) control", "mode \(at(p, 2))") }
            if !out, let t = RingDecode.touch(p) {
                return ("\(t.isTouch ? "Touch" : "Gesture") control", "mode \(t.mode)")
            }
            return (out ? "Read \(control) control" : "Touch control", ack(p, out))
        case RingOp.musicSwitch:
            if out, at(p, 0) == 2 { return ("Ring input reporting", onOff(at(p, 1) == 1)) }
            return (out ? "Read input reporting" : "Input reporting", ack(p, out))
        case RingOp.musicCommand:
            guard !out else { return ("Music state", "") }
            return ("Ring input", RingInput(musicAction: at(p, 0))?.label ?? "action \(at(p, 0))")
        case RingOp.dnd:
            if out, at(p, 0) == 2 {
                return ("Set do not disturb",
                        join(onOff(at(p, 1) == 1), "\(hhmm(at(p, 2), at(p, 3)))–\(hhmm(at(p, 4), at(p, 5)))"))
            }
            if !out, let d = RingDecode.dnd(p) {
                return ("Do not disturb",
                        join(onOff(d.enabled), "\(hhmm(d.startHour, d.startMinute))–\(hhmm(d.endHour, d.endMinute))"))
            }
            return (out ? "Read do not disturb" : "Do not disturb", ack(p, out))
        case RingOp.temperatureUnit:
            if out, at(p, 0) == 2 { return ("Set temperature unit", at(p, 2) == 1 ? "°C" : "°F") }
            if !out, let u = RingDecode.temperatureUnit(p) { return ("Temperature unit", u.celsius ? "°C" : "°F") }
            return (out ? "Read temperature unit" : "Temperature unit", ack(p, out))
        case RingOp.goals:
            if out, at(p, 0) == 2 { return ("Set daily goals", "\(u24(p, 1)) steps") }
            if !out, let g = RingDecode.goals(p) {
                return ("Daily goals", "\(g.steps) steps, \(g.calories / 1000) kcal, \(g.distanceMeters) m")
            }
            return (out ? "Read daily goals" : "Daily goals", ack(p, out))
        case RingOp.profile:
            if out, at(p, 0) == 2 { return ("Set body profile", "\(at(p, 4)) y, \(at(p, 5)) cm, \(at(p, 6)) kg") }
            if !out, let profile = RingDecode.profile(p) {
                return ("Body profile", "\(profile.age) y, \(profile.heightCm) cm, \(profile.weightKg) kg")
            }
            return (out ? "Read body profile" : "Body profile", ack(p, out))
        case RingOp.wearHand:
            if !out, let hand = RingDecode.wearHand(p) { return ("Wear hand", hand.left ? "left" : "right") }
            return (out ? "Read wear hand" : "Wear hand", ack(p, out))
        case RingOp.sedentaryWrite:
            return ("Set sedentary reminder", "every \(at(p, 5)) min")
        case RingOp.sedentaryRead:
            if !out, let s = RingDecode.sedentary(p) {
                return ("Sedentary reminder", join(onOff(s.weekMask != 0), "every \(s.cycleMinutes) min"))
            }
            return ("Read sedentary reminder", "")
        case RingOp.findRing:
            return ("Find ring", out ? "buzz and flash" : "acknowledged")
        case RingOp.findPhone:
            return ("Ring asked to find the phone", at(p, 0) == 1 ? "started" : "stopped")
        case RingOp.powerOff:
            return ("Power the ring off", "")
        case RingOp.factoryReset:
            return ("Factory-reset the ring", "")
        case RingOp.measure:
            if out { return ("Start measurement", measurementName(at(p, 0))) }
            guard let reading = RingDecode.measurement(p) else { return ("Measurement", "") }
            return ("Measurement", measurementDetail(reading))
        case RingOp.stopMeasure:
            return ("Stop measurement", measurementName(at(p, 0)))
        case RingOp.heartRateKeepAlive:
            return ("Keep the heart-rate sensor awake", "")
        case RingOp.phoneStillTime:
            return ("Told the ring whether the phone is in use", at(p, 1) == 1 ? "in use" : "idle")
        case RingOp.calibration:
            return ("Wearing calibration", out ? "" : "step \(at(p, 0)): \(at(p, 1) == 1 ? "ok" : "failed")")
        case RingOp.todayActivity:
            guard !out, let activity = RingDecode.activity(p) else { return ("Read today's totals", "") }
            return ("Today's totals", "\(activity.steps) steps, \(Int(activity.kilocalories)) kcal, \(activity.distanceMeters) m")
        case RingOp.stepDetail:
            return (out ? "Read step slots" : "Step slots", out ? day(at(p, 0)) : slotDetail(p))
        case RingOp.legacySleep:
            return (out ? "Read sleep (legacy)" : "Sleep (legacy)", out ? day(at(p, 0)) : slotDetail(p))
        case RingOp.heartRateHistory:
            return (out ? "Read heart-rate history" : "Heart-rate history", out ? "" : "packet \(at(p, 0))")
        case RingOp.hrvHistory:
            return (out ? "Read HRV history" : "HRV history", out ? day(at(p, 0)) : "packet \(at(p, 0))")
        case RingOp.stressHistory:
            return (out ? "Read stress history" : "Stress history", out ? day(at(p, 0)) : "packet \(at(p, 0))")
        case RingOp.bloodPressureHistory:
            return (out ? "Read blood-pressure history" : "Blood-pressure record", "")
        case RingOp.ppgData:
            return ("Optical sensor samples", "\(p.count) bytes")
        case RingOp.ecgData:
            return ("ECG samples", "\(p.count) bytes")
        case RingOp.packageLength:
            return ("Large-data chunk size", "\(at(p, 0)) bytes")
        case RingOp.deviceEvent:
            return event(p)
        case RingOp.camera:
            return out ? ("Camera control", "") : ("Ring input", "shutter")
        case RingOp.sportEvent:
            return ("Workout event", "type \(at(p, 0))")
        default:
            return (String(format: out ? "Sent command 0x%02X" : "Command 0x%02X", frame.cmd), "")
        }
    }

    /// `0x73` pushes: the ring telling the phone something happened.
    private static func event(_ p: [UInt8]) -> (title: String, detail: String) {
        switch RingDecode.deviceEvent(p) {
        case .dataUpdated(let metric):
            return ("New \(metric.rawValue.replacingOccurrences(of: "_", with: " ")) data", "the ring has more to sync")
        case .battery(let battery):
            return ("Battery", "\(battery.percent)%" + (battery.charging ? ", charging" : ""))
        case .goalsChanged:
            return ("Goals changed on the ring", "")
        case .wearHand(let flag):
            return ("Wear hand changed", flag == 1 ? "left" : "right")
        case .liveActivity(let activity):
            return ("Live activity", "\(activity.steps) steps, \(activity.distanceMeters) m")
        case .settingsChanged:
            return ("Settings changed on the ring", "")
        case .touchSleep(let on):
            return ("Touch-to-sleep", onOff(on))
        case .touchKey(let key):
            return ("Ring input", RingInput(touchKey: key)?.label ?? "key \(key)")
        case .press(let input):
            return ("Ring input", input.label)
        case .instantHeartRate(let bpm):
            return ("Heart rate", "\(bpm) bpm")
        case .instantSpO2(let percent):
            return ("Blood oxygen", "\(percent)%")
        case .liveTemperature(let celsius):
            return ("Temperature", String(format: "%.1f °C", celsius))
        case .phoneStillTimeRequest:
            return ("Ring asked whether the phone is in use", "")
        case .other(let type, _):
            return ("Ring event \(type)", "")
        }
    }

    // MARK: Large-data channel

    private static func bigData(_ frame: RingFrame) -> (title: String, detail: String) {
        let name: String
        switch frame.cmd {
        case RingOp.bigSleep: name = "sleep"
        case RingOp.bigNaps: name = "naps"
        case RingOp.bigManualHeartRate: name = "manual heart-rate readings"
        case RingOp.bigManualSpO2: name = "manual SpO₂ readings"
        case RingOp.bigSpO2: name = "hourly SpO₂"
        case RingOp.bigBloodSugar: name = "hourly blood sugar"
        case RingOp.bigIntervalHeartRate: name = "heart-rate series"
        case RingOp.bigIntervalSpO2: name = "SpO₂ series"
        case RingOp.bigIntervalTemperature: name = "temperature series"
        default: name = String(format: "large data 0x%02X", frame.cmd)
        }
        if frame.outbound { return ("Read \(name)", "") }
        return (name.prefix(1).uppercased() + name.dropFirst(), "\(frame.payload.count) bytes")
    }

    // MARK: Bits and pieces

    private static func at(_ p: [UInt8], _ i: Int) -> Int { i < p.count ? Int(p[i]) : 0 }
    private static func u24(_ p: [UInt8], _ i: Int) -> Int { at(p, i) | (at(p, i + 1) << 8) | (at(p, i + 2) << 16) }
    private static func onOff(_ on: Bool) -> String { on ? "on" : "off" }
    private static func hhmm(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
    private static func every(_ minutes: Int) -> String { minutes > 0 ? "every \(minutes) min" : "" }

    private static func day(_ offset: Int) -> String {
        switch offset {
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(offset) days ago"
        }
    }

    private static func join(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// A settings frame that isn't the read reply is the ring acknowledging a write.
    private static func ack(_ p: [UInt8], _ outbound: Bool) -> String {
        guard !outbound else { return "" }
        return at(p, 0) == 2 ? "saved" : ""
    }

    private static func clock(_ p: [UInt8]) -> String {
        guard p.count >= 5 else { return "" }
        let value = { (i: Int) in RingProtocol.fromBCD(p[i]) }
        return String(format: "20%02d-%02d-%02d %02d:%02d", value(0), value(1), value(2), value(3), value(4))
    }

    private static func slotDetail(_ p: [UInt8]) -> String {
        at(p, 0) == 0xFF ? "no data" : "packet \(at(p, 4) + 1) of \(at(p, 5))"
    }

    private static func measurementName(_ type: Int) -> String {
        RingMeasurementType(rawValue: UInt8(clamping: type))?.label.lowercased() ?? "type \(type)"
    }

    private static func measurementDetail(_ reading: RingMeasurementReading) -> String {
        let name = measurementName(Int(reading.type))
        if reading.errorCode == 1 { return "\(name): the ring is not being worn" }
        if reading.errorCode != 0 { return "\(name): error \(reading.errorCode)" }
        if reading.type == RingMeasurementType.temperature.rawValue {
            return String(format: "%@: %.1f °C", name, reading.celsius)
        }
        if reading.systolic > 0 { return "\(name): \(reading.systolic)/\(reading.diastolic) mmHg" }
        return reading.value > 0 ? "\(name): \(reading.value)" : "\(name): measuring"
    }
}

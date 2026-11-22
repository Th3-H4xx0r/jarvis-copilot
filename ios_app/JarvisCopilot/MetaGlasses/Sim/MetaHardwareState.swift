import Foundation

/// The simulated glasses' physical state and the Gen 2 rules over it, as pure value logic:
/// battery drain by activity, charging in the case, heat, storage, and what is allowed now.
/// `MetaGlassesSimulator` owns one, ticks it every second (× sim speed) and asks it before acting.
struct MetaHardwareState: Equatable, Sendable {
    // Physical
    var battery = 100.0                 // %
    var caseBattery = 100.0             // %
    var worn = true
    var folded = false
    var inCase = false
    var ledCovered = false
    var inRange = true
    var volume = 60                     // 0…100
    var heat = 0.1                      // 0…1
    var storageUsed: Int64 = 0
    var photoCount = 0
    var videoCount = 0
    var videoMode: MetaVideoMode = .uhd3K30
    var clipLength = MetaGen2Profile.defaultClipLength

    // Activity
    var recording: Recording?
    var streaming = false
    var musicPlaying = false
    var voiceActive = false
    var wifiBusyFor = 0.0               // s of import/transfer left
    var cameraTooHot = false

    struct Recording: Equatable, Sendable {
        var mode: MetaVideoMode
        var elapsed: Double = 0
        var cap: Double
    }

    enum Event: Equatable, Sendable {
        case recordingStopped(seconds: Double, reason: String)
        case streamStopped(reason: String)
        case cameraTooHot
        case cameraCooled
        case poweredOff
        case charged
    }

    var poweredOn: Bool { battery > 0 }
    var charging: Bool { inCase && battery < 100 && caseBattery > 0 }
    var heatLabel: String {
        switch heat {
        case ..<0.4: return "Normal"
        case ..<0.6: return "Warm"
        case ..<MetaGen2Profile.heatCameraOff: return "Hot"
        default: return "Too hot"
        }
    }
    var storageFree: Int64 { MetaGen2Profile.storageUsableBytes - storageUsed }

    // MARK: What's allowed now (nil = allowed, else the glasses' own refusal)

    var unreachableReason: String? {
        if !inRange { return "The glasses are out of range" }
        if !poweredOn { return "The glasses' battery is empty" }
        return nil
    }

    func captureRefusal(bytesNeeded: Int64 = MetaGen2Profile.photoBytes) -> String? {
        if let reason = unreachableReason { return reason }
        if inCase { return "The glasses are in their case" }
        if folded { return "The glasses are folded — unfold them to use the camera" }
        if ledCovered { return "The capture LED is covered — the camera stays off until it's uncovered" }
        if cameraTooHot { return "The glasses are too hot — the camera is off until they cool down" }
        if battery < MetaGen2Profile.lowBatteryCapture { return "Battery too low to use the camera (\(Int(battery))%)" }
        if storageFree < bytesNeeded { return "Glasses storage is full — import to the phone first" }
        return nil
    }

    func videoRefusal() -> String? {
        if recording != nil { return "Already recording" }
        return captureRefusal(bytesNeeded: Int64(videoMode.bytesPerSecond * 5))
    }

    func voiceRefusal() -> String? {
        if let reason = unreachableReason { return reason }
        if inCase { return "The glasses are in their case" }
        if folded { return "The glasses are folded" }
        if !worn { return "The glasses aren't being worn" }
        if battery < MetaGen2Profile.lowBatteryVoice { return "Battery too low for the assistant" }
        return nil
    }

    func audioRefusal() -> String? {
        if let reason = unreachableReason { return reason }
        if inCase || folded { return "The glasses are folded" }
        return nil
    }

    /// A requested clip is capped by the clip-length setting (the glasses stop at it).
    func clipSeconds(requested: Int?) -> Int {
        let want = requested ?? clipLength
        return max(1, min(want, clipLength))
    }

    // MARK: Storage

    mutating func storePhoto() {
        storageUsed += MetaGen2Profile.photoBytes
        photoCount += 1
        battery = max(0, battery - MetaGen2Profile.photoCost)
    }

    mutating func storeVideo(seconds: Double, mode: MetaVideoMode) {
        storageUsed += Int64(mode.bytesPerSecond * seconds)
        videoCount += 1
    }

    mutating func freeStorage(bytes: Int64, photos: Int = 0, videos: Int = 0) {
        storageUsed = max(0, storageUsed - bytes)
        photoCount = max(0, photoCount - photos)
        videoCount = max(0, videoCount - videos)
    }

    // MARK: Time

    /// Advance `seconds` of real time. `speed` (sim speed: 1×, 10×, 60×) scales battery and heat
    /// only — a 30 s clip still records for 30 s. Returns what the glasses did on their own.
    mutating func tick(_ seconds: Double, speed: Double = 1) -> [Event] {
        guard seconds > 0 else { return [] }
        var events: [Event] = []
        let scaled = seconds * max(speed, 0)
        let minutes = scaled / 60

        // Battery
        if inCase {
            if battery < 100, caseBattery > 0 {
                let rate = battery < 80 ? MetaGen2Profile.caseChargePerMinuteFast : MetaGen2Profile.caseChargePerMinuteSlow
                let gained = min(100 - battery, rate * minutes)
                battery += gained
                caseBattery = max(0, caseBattery - gained / MetaGen2Profile.caseChargesFull)
                if battery >= 100 { events.append(.charged) }
            }
        } else if poweredOn {
            battery = max(0, battery - drainPerMinute * minutes)
            if battery == 0 {
                events += stopEverything(reason: "Battery empty")
                events.append(.poweredOff)
            }
        }

        // Heat: approach the hottest active target.
        let (target, tau) = heatTarget
        heat += (target - heat) * (1 - exp(-scaled / tau))
        if wifiBusyFor > 0 || streaming { heat = max(heat, min(0.45, heat + 0.05 * scaled)) }
        wifiBusyFor = max(0, wifiBusyFor - seconds)
        if !cameraTooHot, heat >= MetaGen2Profile.heatCameraOff {
            cameraTooHot = true
            events.append(.cameraTooHot)
            if let rec = recording { events.append(.recordingStopped(seconds: rec.elapsed, reason: "Too hot")); finishRecording() }
            if streaming { streaming = false; events.append(.streamStopped(reason: "Too hot")) }
        } else if cameraTooHot, heat < MetaGen2Profile.heatCameraBack {
            cameraTooHot = false
            events.append(.cameraCooled)
        }

        // Recording: the clip cap, low battery, full storage.
        if var rec = recording {
            rec.elapsed += seconds
            recording = rec
            if rec.elapsed >= rec.cap {
                events.append(.recordingStopped(seconds: rec.cap, reason: "Reached the \(Int(rec.cap)) s clip length"))
                finishRecording(at: rec.cap)
            } else if battery < MetaGen2Profile.lowBatteryCapture {
                events.append(.recordingStopped(seconds: rec.elapsed, reason: "Battery low"))
                finishRecording()
            } else if Double(storageFree) < rec.mode.bytesPerSecond * rec.elapsed {
                events.append(.recordingStopped(seconds: rec.elapsed, reason: "Storage full"))
                finishRecording()
            }
        }
        if streaming, battery < MetaGen2Profile.lowBatteryCapture {
            streaming = false
            events.append(.streamStopped(reason: "Battery low"))
        }
        return events
    }

    /// Changing the physical state can stop things at once: covering the LED stops capture,
    /// folding or casing ends audio and capture, leaving range drops everything.
    mutating func applyPhysicalChange() -> [Event] {
        if !inRange || !poweredOn { return stopEverything(reason: inRange ? "Battery empty" : "Out of range") }
        if inCase { folded = true }
        if inCase || folded { return stopEverything(reason: inCase ? "Put in the case" : "Folded") }
        if !worn { musicPlaying = false }
        if ledCovered {
            var events: [Event] = []
            if let rec = recording { events.append(.recordingStopped(seconds: rec.elapsed, reason: "Capture LED covered")); finishRecording() }
            if streaming { streaming = false; events.append(.streamStopped(reason: "Capture LED covered")) }
            return events
        }
        return []
    }

    mutating func startRecording(seconds: Int) {
        recording = Recording(mode: videoMode, cap: Double(seconds))
    }

    /// Ends a recording and stores what was captured. Returns the seconds kept.
    @discardableResult
    mutating func finishRecording(at elapsed: Double? = nil) -> Double {
        guard let rec = recording else { return 0 }
        let kept = min(elapsed ?? rec.elapsed, rec.cap)
        recording = nil
        if kept > 0 { storeVideo(seconds: kept, mode: rec.mode) }
        return kept
    }

    // MARK: Internals

    private var drainPerMinute: Double {
        if inCase || folded { return MetaGen2Profile.drainFolded }
        var rate = worn ? MetaGen2Profile.drainIdle : MetaGen2Profile.drainFolded
        if musicPlaying { rate = max(rate, MetaGen2Profile.drainMusic) }
        if voiceActive { rate = max(rate, MetaGen2Profile.drainVoice) }
        if wifiBusyFor > 0 { rate = max(rate, MetaGen2Profile.drainWiFiTransfer) }
        if streaming { rate = max(rate, MetaGen2Profile.drainStreaming) }
        if let rec = recording { rate = max(rate, rec.mode.drainPerMinute) }
        return rate
    }

    private var heatTarget: (Double, Double) {
        var best: (Double, Double) = (0.1, MetaGen2Profile.heatCoolTau)
        func consider(_ t: (Double, Double)) { if t.0 > best.0 { best = t } }
        if musicPlaying { consider((0.2, 300)) }
        if voiceActive { consider((0.25, 300)) }
        if wifiBusyFor > 0 { consider((0.55, 120)) }
        if streaming { consider((0.95, 400)) }
        if let rec = recording { consider(rec.mode.heat) }
        return best
    }

    private mutating func stopEverything(reason: String) -> [Event] {
        var events: [Event] = []
        if let rec = recording { events.append(.recordingStopped(seconds: rec.elapsed, reason: reason)); finishRecording() }
        if streaming { streaming = false; events.append(.streamStopped(reason: reason)) }
        musicPlaying = false
        voiceActive = false
        return events
    }
}

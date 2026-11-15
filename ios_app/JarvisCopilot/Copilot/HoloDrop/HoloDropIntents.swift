import ActivityKit
import AppIntents
import Darwin
import Foundation

/// "Holo Drop Screen": what Back Tap and the Control Center button run, through a Shortcut that
/// shows the island loader (`HoloDropLoadingIntent`), takes a screenshot and hands it here. Opens Jarvis on the Orbit with the screenshot; when
/// Jarvis recognises the web page in it, that link goes along too, marked "best guess".
struct HoloDropScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Holo Drop Screen"
    static let description = IntentDescription(
        "Drop a screenshot onto another device — and the page it shows, when Jarvis recognises it.")
    static let openAppWhenRun = true

    /// Optional: run on its own (no screenshot step) it opens Holo Drop with the newest photo.
    @Parameter(title: "Screenshot")
    var image: IntentFile?

    /// No reply: a Siri reply (even an empty one) leaves a "Done" card over the screen after Back Tap.
    @MainActor
    func perform() async throws -> some IntentResult {
        HoloScreenTrace.log("screen.perform", "bytes=\(image?.data.count ?? 0)")
        HoloGrab.end()                                        // Jarvis is in front now: the loader's job is done
        guard PowerState.shared.isOn("holo-drop") else { return .result() }
        guard let image else {
            // Run without a screenshot (an old shortcut with no Take Screenshot step): say so,
            // rather than silently sending the wrong photo.
            HoloLauncher.shared.openQuick(note: "No screenshot came in — add the shortcut again from the Holo Drop page")
            return .result()
        }
        let name = "Screenshot \(Date().formatted(.dateTime.hour().minute().second())).png"
            .replacingOccurrences(of: ":", with: ".")
        let dir = HoloTemp.root.appendingPathComponent("screen-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try image.data.write(to: url)
        // Open at once with the screenshot; if it shows a photo from his library, swap in the original.
        let model = HoloLauncher.shared.present(.file(url, name: name, mime: "image/png", kind: "image"), guessFrom: url)
        HoloScreenTrace.log("screen.presented")
        Task { @MainActor in
            let t0 = Date()
            guard let asset = await HoloScreenPhoto.findOriginal(for: url) else {
                HoloScreenTrace.log("match.none", "ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
                return
            }
            HoloScreenTrace.log("match.found", "ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            guard let original = await HoloQuickPick.export(asset) else {
                HoloScreenTrace.log("match.export-failed")
                return
            }
            guard let model, model.phase == .choosing || model.phase == .loading else {
                HoloScreenTrace.log("match.too-late", "ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
                return
            }
            model.item = original
            model.extra = nil                                  // a photo, not a web page: no best-guess link
            model.errorText = "Sending the original photo"
            HoloScreenTrace.log("match.swapped", "ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        }
        return .result()
    }
}

/// "Open Holo Drop" from Shortcuts/Siri: the Holo Drop page.
struct OpenHoloDropIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Holo Drop"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        HoloLauncher.shared.openQuick()
        return .result()
    }
}

/// The Back Tap shortcut's first step: Holo Drop's loader in the Dynamic Island, started in the
/// background so it shows while the screenshot is taken and Jarvis comes forward.
struct HoloDropLoadingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Holo Drop Loading"
    static let description = IntentDescription("Shows Holo Drop's loader in the Dynamic Island while the screen is grabbed.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        HoloScreenTrace.log("loader.perform")
        if PowerState.shared.isOn("holo-drop") { HoloGrab.start() }
        return .result()
    }
}

/// The loader's lifetime: started by the shortcut, ended once Jarvis is in front (or the next
/// time the app opens, if the shortcut stopped halfway).
@MainActor
enum HoloGrab {
    static func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            HoloScreenTrace.log("loader.off", "Live Activities are turned off")
            return
        }
        end()                                                  // one left from a run that never reached Jarvis
        let state = HoloGrabText.state()
        do {
            _ = try Activity.request(attributes: HoloGrabActivityAttributes(),
                                     content: .init(state: state, staleDate: state.until.addingTimeInterval(20)),
                                     pushType: nil)
            HoloScreenTrace.log("loader.shown")
        } catch {
            HoloScreenTrace.log("loader.failed", error.localizedDescription)
        }
    }

    static func end() {
        for activity in Activity<HoloGrabActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

/// Where the time goes between Back Tap and the Orbit: one line per step in
/// Documents/holo-screen.log (pull it with devicectl). `age` = seconds since this app process
/// started, so a cold launch shows up as a small age.
enum HoloScreenTrace {
    private static let queue = DispatchQueue(label: "holo.screen.trace")

    static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("holo-screen.log")
    }

    static func log(_ event: String, _ detail: String = "") {
        let now = Date()
        let age = processStart.map { String(format: "%.2f", now.timeIntervalSince($0)) } ?? "?"
        let line = "\(now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(event) age=\(age) \(detail)"
        HoloMotionTrace.write(line, to: url, on: queue)
    }

    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()
}

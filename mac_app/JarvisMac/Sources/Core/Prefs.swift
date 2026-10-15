import AppKit
import ServiceManagement

/// The Mac app's settings (UserDefaults), in one place.
enum Prefs {
    private static var d: UserDefaults { .standard }

    static var display: IslandDisplayChoice {
        get { IslandDisplayChoice(rawValue: d.string(forKey: "island.display") ?? "notch") }
        set { d.set(newValue.rawValue, forKey: "island.display") }
    }

    /// Open the island when the pointer reaches it (else only on a click).
    static var openOnHover: Bool {
        get { d.object(forKey: "island.openOnHover") as? Bool ?? false }
        set { d.set(newValue, forKey: "island.openOnHover") }
    }

    /// Hide the island completely when nothing runs (else the compact pill stays).
    static var hideWhenIdle: Bool {
        get { d.object(forKey: "island.hideWhenIdle") as? Bool ?? true }
        set { d.set(newValue, forKey: "island.hideWhenIdle") }
    }

    static var soundOn: Bool {
        get { d.object(forKey: "sound.on") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound.on") }
    }

    static var volume: Double {
        get { d.object(forKey: "sound.volume") as? Double ?? 0.5 }
        set { d.set(max(0, min(1, newValue)), forKey: "sound.volume") }
    }

    /// "auto" or an OrbSkin raw value.
    static var skin: String {
        get { d.string(forKey: "orb.skin") ?? "standard" }
        set { d.set(newValue, forKey: "orb.skin") }
    }

    static var desktopOrb: Bool {
        get { d.bool(forKey: "orb.desktop") }
        set { d.set(newValue, forKey: "orb.desktop") }
    }

    static var desktopOrbOrigin: CGPoint? {
        get {
            guard let a = d.array(forKey: "orb.desktopOrigin") as? [Double], a.count == 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "orb.desktopOrigin") }
    }

    /// Start Jarvis at login (SMAppService, the system's own list).
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Jarvis: launch at login: \(error)")
            }
        }
    }
}

/// The app's sounds: macOS system sounds by name (nothing bundled), each one
/// replaceable by a file in ~/Library/Application Support/Jarvis/Sounds named
/// after the event (needs-you.aiff, finished.wav, …).
@MainActor
enum Sounds {
    enum Event: String, CaseIterable {
        case needsYou = "needs-you", finished, failed, started, decided

        var systemName: String {
            switch self {
            case .needsYou: return "Glass"
            case .finished: return "Hero"
            case .failed: return "Basso"
            case .started: return "Tink"
            case .decided: return "Pop"
            }
        }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jarvis/Sounds", isDirectory: true)
    }

    private static var cache: [Event: NSSound] = [:]

    static func play(_ event: Event) {
        guard Prefs.soundOn else { return }
        let sound = cache[event] ?? load(event)
        cache[event] = sound
        guard let sound else { return }
        sound.stop()
        sound.volume = Float(Prefs.volume)
        sound.play()
    }

    static func reload() { cache = [:] }

    private static func load(_ event: Event) -> NSSound? {
        for ext in ["wav", "aiff", "aif", "caf", "m4a", "mp3"] {
            let url = folder.appendingPathComponent("\(event.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path), let s = NSSound(contentsOf: url, byReference: true) {
                return s
            }
        }
        return NSSound(named: NSSound.Name(event.systemName))
    }
}

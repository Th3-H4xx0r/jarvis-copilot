import Foundation

/// The Ray-Ban Meta (Gen 2) hardware limits the simulator enforces: one place, sourced.
/// "assumed" marks a figure nobody publishes; change it here when the real glasses say otherwise.
/// Sources: Meta's Gen 2 page and launch post (battery, 3K, case), Meta release notes v6 (3 min clips),
/// reviews (12 MP 3024×4032, 32 GB, Wi-Fi 6, BT 5.3), docs/glasses/2026-11-21-meta-ray-ban-gen2-research.md
/// (streaming drain, heat, Wi-Fi import, live 720p, touch defaults, LED).
enum MetaGen2Profile {
    // Camera
    static let photoWidth = 3024
    static let photoHeight = 4032                 // 12 MP, portrait
    static let visionMaxEdge = 1440               // the copy Jarvis's vision gets (DAT stills are 1080×1440)
    static let photoBytes: Int64 = 4_000_000      // per 12 MP JPEG (assumed)
    static let liveWidth = 720
    static let liveHeight = 1280
    static let liveFPS = 30

    // Clips
    static let clipLengths = [30, 60, 180]        // seconds; 3 min max (release notes v6)
    static let defaultClipLength = 30

    // Storage
    static let storageTotalBytes: Int64 = 32_000_000_000
    static let storageUsableBytes: Int64 = 28_000_000_000   // after system (assumed)

    // Battery (percent per minute)
    static let typicalUseHours = 8.0
    static let drainIdle = 0.06                   // worn, nothing running (assumed)
    static let drainFolded = 0.01                 // folded, link only (assumed)
    static let drainMusic = 0.20                  // ≈ 8 h of typical use
    static let drainVoice = 0.30                  // assistant turn (assumed)
    static let drainRecording3K = 2.0             // research: streaming/3K 1.2–2 %/min
    static let drainRecordingOther = 1.4
    static let drainStreaming = 1.6
    static let drainWiFiTransfer = 1.2
    static let photoCost = 0.1                    // one-off % per photo (assumed)
    static let caseChargePerMinuteFast = 2.5      // 50 % in 20 min
    static let caseChargePerMinuteSlow = 1.0      // above 80 % (assumed taper)
    static let caseExtraHours = 48.0              // case holds 6 full charges
    static var caseChargesFull: Double { caseExtraHours / typicalUseHours }
    static let lowBatteryCapture = 10.0           // capture refused / recording ends below (assumed)
    static let lowBatteryVoice = 2.0              // assistant refused below (assumed)

    // Heat (0…1): fair ≥ 0.4, serious ≥ 0.6, camera off ≥ 0.85, back on below 0.5
    static let heatCameraOff = 0.85
    static let heatCameraBack = 0.5
    static let heatCoolTau = 280.0                // s: back from too-hot in ~3–5 min

    // Media transfer over the glasses' Wi-Fi (phone leaves home Wi-Fi meanwhile)
    static let wifiBytesPerSecond = 10_000_000.0
    static let wifiJoinSeconds = 4.0              // (assumed)

    // Wake word
    static let wakeLanguages = ["en-US"]
    static let wakeEnrolSamples = 3
}

/// The glasses' video modes (Meta's Gen 2 page). Pixel sizes and bitrates are assumed.
enum MetaVideoMode: String, CaseIterable, Codable, Sendable {
    case uhd3K30, fhd30, fhd60, hd120

    var label: String {
        switch self {
        case .uhd3K30: return "3K · 30 fps"
        case .fhd30: return "1080p · 30 fps"
        case .fhd60: return "1080p · 60 fps"
        case .hd120: return "720p · 120 fps"
        }
    }
    var width: Int { switch self { case .uhd3K30: return 2208; case .fhd30, .fhd60: return 1440; case .hd120: return 1080 } }
    var height: Int { switch self { case .uhd3K30: return 2944; case .fhd30, .fhd60: return 1920; case .hd120: return 1440 } }
    var fps: Int { switch self { case .uhd3K30, .fhd30: return 30; case .fhd60: return 60; case .hd120: return 120 } }
    var bytesPerSecond: Double { switch self { case .uhd3K30: return 7_500_000; case .fhd30: return 3_100_000; case .fhd60: return 5_000_000; case .hd120: return 6_000_000 } }
    var drainPerMinute: Double { self == .uhd3K30 ? MetaGen2Profile.drainRecording3K : MetaGen2Profile.drainRecordingOther }
    /// Heat target and time constant while recording: 3K crosses camera-off after ~15 min.
    var heat: (target: Double, tau: Double) {
        switch self {
        case .uhd3K30: return (1.0, 502)
        case .fhd30: return (0.8, 600)
        case .fhd60, .hd120: return (0.9, 600)
        }
    }
}

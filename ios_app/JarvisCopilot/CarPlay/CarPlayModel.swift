import Foundation

// What a CarPlay screen shows, as plain values. The screen builders
// (`CarPlayScreens`) turn store state into these; `CarPlayRenderer` turns them
// into Apple's templates; `CarPlayCoordinator` runs the actions. Keeping the
// middle layer free of CarPlay types is what lets every screen be unit-tested.

enum CarPlayTint: Equatable { case accent, success, amber, danger, muted }

struct CarPlayRow: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String? = nil
    var symbol: String? = nil
    var tint: CarPlayTint? = nil
    /// A dashcam clip whose thumbnail the renderer loads into the row.
    var clipThumbID: String? = nil
    /// The Jarvis orb as the row's image.
    var orb = false
    var enabled = true
    /// The current pick in a list of choices.
    var checked = false
    var action: CarPlayAction = .none
}

struct CarPlaySection: Equatable {
    var title: String?
    var rows: [CarPlayRow]
}

/// An information screen: label/value pairs and up to three buttons.
struct CarPlayInfo: Equatable {
    var title: String
    var items: [CarPlayInfoItem]
    var actions: [CarPlayRow] = []
}

struct CarPlayInfoItem: Equatable {
    var title: String
    var detail: String
}

/// Every screen pushed over a tab. CarPlay's voice-based conversational apps
/// may stack at most three templates, the tab's own list included.
enum CarPlayScreen: Hashable {
    /// The dashcam and its sub-screens.
    case dashcam, clip(id: String), drives, dashcamSettings
    /// A car-enabled wearable without a screen of its own: its status.
    case device(id: String)

    var depth: Int {
        switch self {
        case .dashcam, .device: return 2
        case .clip, .drives, .dashcamSettings: return 3
        }
    }

    static let maxDepth = 3
}

enum CarPlayAction: Equatable {
    case none
    case push(CarPlayScreen)
    case startVoice
    case dashcam(CarPlayDashcamCommand)
    case clip(id: String, CarPlayClipCommand)
}

enum CarPlayDashcamCommand: Equatable {
    case record, photo, lock, mic(Bool)
    case syncNow, reconnect, cloudBackup(Bool), loadMore
    case liveActivity(Bool), autoSync(Bool)
    case chooseRule(CarPlayRuleKey), toggleRule(CarPlayRuleKey)
    case chooseSetting(String), syncClock
}

enum CarPlayClipCommand: Equatable { case download, retryUpload, delete }

/// The dashcam's sync and upload rules, as the settings screen edits them.
enum CarPlayRuleKey: Equatable { case normal, normalWhen, phoneCap, keepOnPhone, upload, uploadData, uploadWhen }

/// The coordinator's record of pushed screens, kept in step with CarPlay's own
/// navigation stack (a pop-to-root reports only the screen that was on top).
enum CarPlayStack {
    static func kept<Entry>(_ entries: [Entry], template: (Entry) -> AnyObject, visible: [AnyObject]) -> [Entry] {
        entries.filter { entry in visible.contains { $0 === template(entry) } }
    }
}

/// The sections each list last showed, so a store change that alters nothing on
/// screen doesn't rebuild it (new items reload thumbnails and flicker).
struct CarPlaySectionsCache {
    private var last: [ObjectIdentifier: [CarPlaySection]] = [:]

    /// True when `sections` differ from what `key` last showed (and records them).
    mutating func changed(_ key: ObjectIdentifier, _ sections: [CarPlaySection]) -> Bool {
        guard last[key] != sections else { return false }
        last[key] = sections
        return true
    }

    mutating func forget(_ key: ObjectIdentifier) { last[key] = nil }
}

// MARK: Inputs (plain snapshots of the stores, so the builders stay pure)

/// A car-enabled wearable as the Wearables tab lists it.
struct CarPlayCarDevice: Equatable {
    var id: String
    var name: String
    var status: String
    var connected: Bool
    /// The dashcam opens its own screens; anything else opens its status.
    var isDashcam: Bool
}

struct CarPlayDashcamInput {
    var onCamera: Bool
    var phaseLabel: String
    var recording: Bool?
    var sdFreeBytes: Int64?
    var subtitle: String
    var downloading: (name: String, done: Int64, total: Int64)?
    var uploading: (clipID: String, done: Int64, total: Int64)?
    var cloudBackupOn: Bool
    var uploadNote: String?
    var passActive: Bool
    var mic: DashcamMic?
    /// A Wi‑Fi password is saved, so Reconnect can join without typing.
    var canReconnect: Bool
    var filter: DashcamLibraryModel.Filter
    var clips: [DashcamServerClip]
    var canLoadMore: Bool
    var libraryError: String?
    var pendingUploads = 0
}

struct CarPlayDashcamSettingsInput {
    var liveActivity: Bool
    var autoSync: Bool
    var rules: DashcamRules
    var rulesLoaded: Bool
    var onCamera: Bool
    var cameraItems: [DashcamSettingItem]
    var sd: DashcamSDInfo?
}

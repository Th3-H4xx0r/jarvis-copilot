import ActivityKit
import Foundation
import Photos
import QuickLook
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// A drop that arrived for this device (`GET /drops/<id>`, a bridge `drop` frame, or the LAN).
struct HoloDropRecord: Identifiable, Equatable {
    let id: String
    let kind: String            // link | text | image | video | file
    let from: String
    let fromName: String
    let name: String
    let mime: String
    let size: Int
    let text: String
    let url: String
    let title: String
    let action: HoloAction

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty,
              let kind = json["kind"] as? String, ["link", "text", "image", "video", "file"].contains(kind) else { return nil }
        self.id = id
        self.kind = kind
        from = json["from"] as? String ?? json["sender"] as? String ?? ""
        fromName = json["from_name"] as? String ?? ""
        name = json["name"] as? String ?? ""
        mime = json["mime"] as? String ?? ""
        size = (json["size"] as? NSNumber)?.intValue ?? 0
        text = json["text"] as? String ?? ""
        url = json["url"] as? String ?? ""
        title = json["title"] as? String ?? ""
        action = HoloAction(rawValue: json["action"] as? String ?? "") ?? .save
    }

    var isFile: Bool { ["image", "video", "file"].contains(kind) }

    /// Only web links open: a drop never launches an arbitrary URL scheme.
    var webURL: URL? {
        guard kind == "link", let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return u
    }

    var caption: String {
        switch kind {
        case "link": return title.isEmpty ? (webURL?.host ?? url) : title
        case "text": return String(text.prefix(120))
        default: return name.isEmpty ? "A file" : name
        }
    }

    var symbol: String { HoloDropActivityText.symbol(kind) }

    var sender: String { fromName.isEmpty ? "another device" : fromName }
}

/// What a drop's action does for its kind, and the outcome reported back to the sender.
enum HoloArrival {
    struct Plan: Equatable {
        var save = false
        var open = false
        var copy = false
        var outcome: String
    }

    static func plan(_ action: HoloAction, kind: String) -> Plan {
        switch action {
        case .save: return Plan(save: true, outcome: "saved")
        case .open: return Plan(open: true, outcome: "opened")
        case .copy: return Plan(copy: true, outcome: "copied")
        case .saveOpen: return Plan(save: true, open: true, outcome: "saved_opened")
        case .saveCopy: return Plan(save: true, copy: true, outcome: "saved_copied")
        }
    }

    /// "Opened", "Saved + copied" — what the card and the sender read.
    static func words(_ outcome: String) -> String {
        let w = HoloOutcomeWords.text(outcome)
        return w.isEmpty ? "Done" : w
    }

    /// A file name safe to write: no path parts, not hidden, not empty, ≤ 120 characters.
    static func safeName(_ raw: String, fallback: String = "Holo Drop") -> String {
        var s = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = fallback }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            let stem = String((s as NSString).deletingPathExtension.prefix(ext.isEmpty ? 120 : 119 - ext.count))
            s = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return s
    }

    /// `dir/name`, or `dir/name 2.ext`… when that's taken (never overwrite an earlier drop).
    static func uniqueURL(in dir: URL, name: String,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = dir.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

/// Holo Drop's own saved list: links and text he chose to save (files go to Files, photos to Photos).
@MainActor
final class HoloSavedList: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        let id: String
        let kind: String
        let text: String
        let url: String
        let title: String
        let from: String
        let at: Date
    }

    static let shared = HoloSavedList()
    static let cap = 200
    @Published private(set) var items: [Entry] = []
    private let key: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, key: String = "holoDrop.saved") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            items = list
        }
    }

    func add(_ r: HoloDropRecord, at: Date = Date()) {
        guard !items.contains(where: { $0.id == r.id }) else { return }
        items.insert(Entry(id: r.id, kind: r.kind, text: r.text, url: r.url, title: r.title, from: r.sender, at: at), at: 0)
        if items.count > Self.cap { items.removeLast(items.count - Self.cap) }
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}

/// One arrival on screen.
struct HoloArrivalCard: Identifiable, Equatable {
    enum State: Equatable { case working, done(String), failed(String) }
    let record: HoloDropRecord
    var state: State = .working
    var expanded = false            // text "open": the card shows the whole text
    var fileURL: URL?               // a received file (Quick Look / Save / Copy again)
    var id: String { record.id }
}

/// Receives Holo Drops on the iPhone/iPad: a card when the app is open (it does the chosen
/// action at once), a banner + "Drop waiting" Live Activity when it isn't (opening the app
/// finishes the job). Follows the Power switch: off = frames ignored, nothing listens.
@MainActor
final class HoloDropReceiver: ObservableObject {
    static let shared = HoloDropReceiver()

    @Published private(set) var cards: [HoloArrivalCard] = []
    /// The last `landed` news for a drop this device sent (an open popup shows it).
    @Published private(set) var lastLanded: (id: String, text: String)?
    private(set) var running = false
    private var handled: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private let overlay = HoloCardsWindow()
    private var tokenTask: Task<Void, Never>?

    var client: HoloDropClient? {
        guard let base = BridgeClient.shared.apiBaseURL() else { return nil }
        return HoloDropClient(baseURL: base, headers: BridgeClient.shared.apiAuthHeaders(),
                              session: BridgeClient.shared.urlSession)
    }

    func start() {
        guard !running else { return }
        running = true
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HoloDropReceiver.shared.becameActive() }
            },
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HoloLanReceiver.shared.stop() }
            },
        ]
        watchStartToken()
        HoloOrbitModel.showedLanding = { id in HoloDropReceiver.shared.shownLandings.insert(id) }
        Task.detached(priority: .background) { HoloTemp.sweep() }
        if UIApplication.shared.applicationState == .active { becameActive() }
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        tokenTask?.cancel()
        tokenTask = nil
        HoloLanReceiver.shared.stop()
        HoloSensing.shared.stopAll()
        cards = []
        overlay.hide()
        Task { await Self.endActivities() }
        // The server stops push-starting cards: forget this phone's start token.
        Task { _ = try? await JarvisAPI.shared.post("/api/live/activity-token", json: ["source": "holo-start", "token": ""]) }
    }

    private func becameActive() {
        guard running else { return }
        HoloLanReceiver.shared.start()
        Task { await fetchPending() }
    }

    /// The bridge said hello again: anything that waited while we were away.
    func reconnected() {
        guard running, UIApplication.shared.applicationState == .active else { return }
        Task { await fetchPending() }
    }

    // MARK: bridge frames

    func handle(_ msg: [String: Any]) {
        guard running else { return }
        switch msg["event"] as? String {
        case "drop":
            if let rec = (msg["drop"] as? [String: Any]).flatMap(HoloDropRecord.init(json:)) { arrived(rec) }
        case "landed":
            if let d = msg["drop"] as? [String: Any], let id = d["id"] as? String { landed(id: id, drop: d) }
        case "beacon":
            HoloSensing.shared.beacon(msg)
        default:
            break       // screen_request: the iPhone has no screen map (iPadOS can't see other apps' windows)
        }
    }

    /// A drop for this device. Open app → card + action now; otherwise a banner whose tap opens it.
    func arrived(_ rec: HoloDropRecord, file: URL? = nil) {
        guard running, !handled.contains(rec.id) else { return }
        guard UIApplication.shared.applicationState == .active else {
            notify(rec)
            return
        }
        handled.insert(rec.id)
        Task { _ = await receive(rec, file: file, report: true) }
    }

    /// A direct (LAN) drop: performed now, answered to the sender over the same connection.
    func receiveDirect(_ rec: HoloDropRecord, file: URL?) async -> String {
        guard running else { return "failed" }
        handled.insert(rec.id)
        return await receive(rec, file: file, report: false)
    }

    /// The Live Activity / banner tap (`jarviscopilot://holo-drop?drop=<id>`).
    func open(dropID: String?) {
        guard running else { return }
        Task { await fetchPending() }
    }

    func fetchPending() async {
        guard running, UIApplication.shared.applicationState == .active, let client else { return }
        guard let drops = try? await client.pending() else { return }
        for json in drops {
            if let rec = HoloDropRecord(json: json) { arrived(rec) }
        }
        await Self.endActivities()
        let ids = drops.compactMap { ($0["id"] as? String).map { "holo-\($0)" } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Landings a popup already showed (the rest get a banner).
    var shownLandings: Set<String> = []

    private func landed(id: String, drop: [String: Any]) {
        let what = (drop["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (drop["title"] as? String) ?? (drop["url"] as? String) ?? "Your drop"
        let target = drop["target"] as? String ?? ""
        let failed = drop["state"] as? String == "failed"
        let text = failed
            ? "\(what) didn't land: \(drop["error"] as? String ?? "the device couldn't take it")"
            : "\(what) landed · \(HoloArrival.words(drop["outcome"] as? String ?? ""))"
        lastLanded = (id, text)
        // A popup polls for ~4 s; anything it didn't show (it closed, or the Mac woke later) is a banner.
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard !shownLandings.contains(id) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Holo Drop"
            content.body = String(text.prefix(180))
            content.userInfo = ["type": "holo_drop_landed", "id": id, "target": target]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "holo-landed-\(id)", content: content, trigger: nil))
        }
    }

    // MARK: performing

    @discardableResult
    private func receive(_ rec: HoloDropRecord, file: URL?, report: Bool) async -> String {
        show(HoloArrivalCard(record: rec))
        let plan = HoloArrival.plan(rec.action, kind: rec.kind)
        do {
            var local = file
            if rec.isFile, local == nil {
                guard let client else { throw HoloReceiveError.noServer }
                local = try await client.content(rec.id, to: Self.inbox(rec))
            }
            update(rec.id) { $0.fileURL = local }
            try await perform(rec, plan: plan, file: local)
            update(rec.id) { $0.state = .done(HoloArrival.words(plan.outcome)) }
            if report { await client?.landed(rec.id, outcome: plan.outcome) }
            dismissSoon(rec.id)
            return plan.outcome
        } catch {
            let why = error.localizedDescription
            update(rec.id) { $0.state = .failed(why) }
            if report { await client?.landed(rec.id, outcome: "failed", error: why) }
            return "failed"
        }
    }

    private func perform(_ rec: HoloDropRecord, plan: HoloArrival.Plan, file: URL?) async throws {
        switch rec.kind {
        case "link":
            guard let url = rec.webURL else { throw HoloReceiveError.badLink }
            if plan.save { HoloSavedList.shared.add(rec) }
            if plan.copy { UIPasteboard.general.url = url }
            if plan.open { await UIApplication.shared.open(url) }
        case "text":
            if plan.save { HoloSavedList.shared.add(rec) }
            if plan.copy { UIPasteboard.general.string = rec.text }
            if plan.open { update(rec.id) { $0.expanded = true } }
        default:
            guard let file else { throw HoloReceiveError.noFile }
            if plan.save {
                if rec.kind == "image" || rec.kind == "video" {
                    try await Self.saveToPhotos(file, video: rec.kind == "video")
                } else {
                    try Self.saveToFiles(file, name: rec.name)
                }
            }
            if plan.copy { try Self.copy(file, rec: rec) }
            if plan.open { HoloQuickLook.present(file) }
        }
    }

    // MARK: cards

    private func show(_ card: HoloArrivalCard) {
        cards.removeAll { $0.id == card.id }
        cards.insert(card, at: 0)
        if cards.count > 3 { cards.removeLast(cards.count - 3) }
        overlay.show()
    }

    func update(_ id: String, _ change: (inout HoloArrivalCard) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[i])
    }

    func dismiss(_ id: String) {
        if let file = cards.first(where: { $0.id == id })?.fileURL, file.path.hasPrefix(HoloTemp.root.path) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())   // saved copies live on
        }
        cards.removeAll { $0.id == id }
        if cards.isEmpty { overlay.hide() }
    }

    private func dismissSoon(_ id: String) {
        Task {
            try? await Task.sleep(for: .seconds(6))
            // An expanded text card stays until swiped away: he's reading it.
            if let c = cards.first(where: { $0.id == id }), !c.expanded { dismiss(id) }
        }
    }

    /// Card buttons: do one more thing with an arrival (Open / Save / Copy).
    func again(_ id: String, _ action: HoloAction) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        let plan = HoloArrival.plan(action, kind: card.record.kind)
        Task {
            do {
                try await perform(card.record, plan: plan, file: card.fileURL)
                update(id) { $0.state = .done(HoloArrival.words(plan.outcome)) }
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: banner + Live Activity

    private func notify(_ rec: HoloDropRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Holo Drop"
        content.body = "\(rec.sender) dropped \(rec.caption) — tap to get it"
        content.userInfo = ["type": "holo_drop", "id": rec.id, "url": "jarviscopilot://holo-drop?drop=\(rec.id)"]
        let request = UNNotificationRequest(identifier: "holo-\(rec.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func watchStartToken() {
        guard #available(iOS 17.2, *) else { return }
        tokenTask?.cancel()
        tokenTask = Task { @MainActor in
            for await data in Activity<HoloDropActivityAttributes>.pushToStartTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                _ = try? await JarvisAPI.shared.post("/api/live/activity-token", json: ["source": "holo-start", "token": token])
            }
        }
    }

    static func endActivities() async {
        for activity in Activity<HoloDropActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: files

    /// Where a downloaded drop lands before it's saved (temporary; iOS clears it).
    static func inbox(_ rec: HoloDropRecord) -> URL {
        let dir = HoloTemp.root.appendingPathComponent(rec.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(HoloArrival.safeName(rec.name))
    }

    /// Files → On My iPhone → Jarvis → Holo Drop.
    static var filesFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Holo Drop", isDirectory: true)
    }

    static func saveToFiles(_ file: URL, name: String) throws {
        let dir = filesFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = HoloArrival.uniqueURL(in: dir, name: HoloArrival.safeName(name.isEmpty ? file.lastPathComponent : name))
        try FileManager.default.copyItem(at: file, to: dest)
    }

    static func saveToPhotos(_ file: URL, video: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw HoloReceiveError.noPhotos }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: video ? .video : .photo, fileURL: file, options: nil)
        }
    }

    static let copyCap = 50 * 1_048_576

    static func copy(_ file: URL, rec: HoloDropRecord) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= copyCap else { throw HoloReceiveError.tooBigToCopy }
        if rec.kind == "image", let image = UIImage(contentsOfFile: file.path) {
            UIPasteboard.general.image = image
            return
        }
        let type = UTType(mimeType: rec.mime) ?? UTType(filenameExtension: file.pathExtension) ?? .data
        UIPasteboard.general.setData(try Data(contentsOf: file), forPasteboardType: type.identifier)
    }
}

enum HoloReceiveError: LocalizedError {
    case noServer, badLink, noFile, noPhotos, tooBigToCopy

    var errorDescription: String? {
        switch self {
        case .noServer: return "This phone isn't paired with Jarvis"
        case .badLink: return "That link can't be opened"
        case .noFile: return "The file didn't arrive"
        case .noPhotos: return "Jarvis can't add to Photos — allow it in Settings"
        case .tooBigToCopy: return "Too big to copy (over 50 MB) — use Save"
        }
    }
}

/// Quick Look over whatever is on screen.
@MainActor
enum HoloQuickLook {
    private static var source: Source?

    final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }

    static func present(_ url: URL) {
        let s = Source(url: url)
        source = s
        let ql = QLPreviewController()
        ql.dataSource = s
        topController()?.present(ql, animated: true)
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first(where: { $0.windowLevel == .normal })
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// Holo Drop banners and taps.
enum HoloDropPush {
    static func isHoloDrop(_ userInfo: [AnyHashable: Any]) -> Bool {
        let t = userInfo["type"] as? String
        return t == "holo_drop" || t == "holo_drop_landed"
    }

    /// A landing banner ("landed on MacBook") is news only; a drop banner opens the drop.
    static func isArrival(_ userInfo: [AnyHashable: Any]) -> Bool { userInfo["type"] as? String == "holo_drop" }

    static func dropID(_ userInfo: [AnyHashable: Any]) -> String? { userInfo["id"] as? String }
}

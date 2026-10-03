import ActivityKit
import Foundation

/// Runs the dashcam's own Live Activity: up while clips come off the camera (on its Wi‑Fi) or go up to the
/// cloud (from anywhere), gone 20 s after they stop. Watches `DashcamSync` every 2 s; events go out at once, progress at most every 8 s (iOS throttles
/// an app that updates more, and the update it drops is usually the one that mattered).
@MainActor
final class DashcamSyncBeacon {
    static let shared = DashcamSyncBeacon()

    private var activity: Activity<DashcamSyncAttributes>?
    private var sent: DashcamSyncAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var idleSince: Date?
    private var watch: Task<Void, Never>?
    static let progressEvery: TimeInterval = 8
    /// The island holds two activities at most and picks by this score: above JARVIS's always-on one (0), so
    /// the sync takes the island while clips move and gives it back when it ends.
    static let relevance: Double = 100
    static let lingerAfter: TimeInterval = 20

    private init() {}

    /// Settings → "Show sync progress on the Lock Screen" (on unless switched off).
    static let enabledKey = "jc.dashcam.liveActivity"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func start() {
        guard watch == nil else { return }
        // A previous run's activity (killed app): nothing is syncing a moment from now.
        for old in Activity<DashcamSyncAttributes>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tick() {
        let sync = DashcamSync.shared
        guard Self.enabled else { end(); return }
        // Clips coming off the camera (only possible on its Wi‑Fi), or going up to the cloud — from anywhere —
        // or still queued to go up. The queue counts even between batches: iOS only STARTS an activity while
        // the app is in the foreground, so one that ended in a lull couldn't come back in the background.
        let queued = sync.rules.upload && sync.pendingUploads > 0
        let moving = (DashcamWiFi.shared.onCamera && sync.downloading != nil) || sync.uploading != nil || queued
        if !moving {
            if idleSince == nil { idleSince = Date() }
            if let since = idleSince, Date().timeIntervalSince(since) > Self.lingerAfter { end() }
            return
        }
        idleSince = nil
        var s = DashcamSyncAttributes.ContentState()
        if let d = sync.downloading, DashcamWiFi.shared.onCamera {
            s.downloadName = Self.clamp(d.name)
            s.downloadFraction = d.total > 0 ? Double(d.done) / Double(d.total) : 0
            s.toDownload = max(1, sync.queuedDownloads)
        }
        if let u = sync.uploading {
            s.uploading = true
            s.uploadFraction = u.total > 0 ? Double(u.done) / Double(u.total) : 0
            s.toUpload = max(1, sync.pendingUploads)
        } else if queued {
            s.uploading = true                    // between clips: the bar sits at 0 with the count
            s.toUpload = sync.pendingUploads
        }
        push(s)
    }

    private func push(_ s: DashcamSyncAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity else {
            let name = DashcamSetupStore.load()?.displayName ?? "Dashcam"
            do {
                activity = try Activity.request(attributes: DashcamSyncAttributes(cameraName: Self.clamp(name)),
                                                content: ActivityContent(state: s, staleDate: nil, relevanceScore: Self.relevance),
                                                pushType: nil)
            } catch {
                // Typically "not visible": started from the background. It comes up the next time the app is open.
                JcLog.devices.notice("dashcam sync activity: couldn't start (\(error.localizedDescription, privacy: .public))")
                return
            }
            sent = s
            lastPush = Date()
            return
        }
        guard s != sent else { return }
        // A new clip or a transfer starting/stopping is an event; a percentage that merely moved waits.
        let event = sent.map { $0.downloadName != s.downloadName || $0.uploading != s.uploading } ?? true
        guard event || Date().timeIntervalSince(lastPush) >= Self.progressEvery else { return }
        sent = s
        lastPush = Date()
        Task { await activity.update(ActivityContent(state: s, staleDate: nil, relevanceScore: Self.relevance)) }
    }

    private func end() {
        idleSince = nil
        sent = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func clamp(_ text: String) -> String {
        let limit = DashcamSyncAttributes.maxTextChars
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

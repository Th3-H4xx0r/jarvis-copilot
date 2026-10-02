import Foundation
import SwiftUI
import UIKit

/// Speed in the units Pranav reads (mph), and the colour a speed is drawn in on maps and charts.
enum DashcamSpeed {
    static let mphPerMps = 2.236936
    /// Top of the colour scale: at or above this everything is the hottest colour.
    static let rampTopMph = 80.0

    static func mph(_ mps: Double?) -> Double? { mps.map { $0 * mphPerMps } }

    static func text(_ mps: Double?) -> String {
        guard let mph = mph(mps) else { return "–" }
        return "\(Int(mph.rounded()))"
    }

    /// Teal when crawling → green → amber → red at 80 mph (absolute, so drives compare).
    static func color(_ mps: Double?) -> UIColor {
        guard let mph = mph(mps) else { return UIColor(JcTheme.muted) }
        return RoutePalette.blend(RoutePalette.elevationRamp, max(0, min(1, mph / rampTopMph)))
    }

    static func compass(_ heading: Double?) -> String? {
        guard let h = heading, h.isFinite else { return nil }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[i]
    }

    static func miles(_ metres: Double) -> String {
        let mi = metres / 1609.344
        return mi < 10 ? String(format: "%.1f mi", mi) : "\(Int(mi.rounded())) mi"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }
}

/// Where the car was at a moment of a clip, for the player overlay and the map dot.
enum DashcamTrack {
    /// The fix at `t` (Unix seconds): position and speed interpolated between the two fixes
    /// around it, heading from the nearer one. Nil outside the fixes (± 2 s) or with none.
    static func fix(at t: Double, in fixes: [DashcamFix]) -> DashcamFix? {
        guard let first = fixes.first, let last = fixes.last else { return nil }
        if t < first.t - 2 || t > last.t + 2 { return nil }
        if t <= first.t { return first }
        if t >= last.t { return last }
        var lo = 0, hi = fixes.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if fixes[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = fixes[lo], b = fixes[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        func lerp(_ x: Double?, _ y: Double?) -> Double? {
            guard let x else { return y }
            guard let y else { return x }
            return x + (y - x) * f
        }
        return DashcamFix(t: t, lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f,
                          speed: lerp(a.speed, b.speed), heading: f < 0.5 ? (a.heading ?? b.heading) : (b.heading ?? a.heading))
    }
}

/// What the library chip says about a clip.
struct DashcamClipStatus: Equatable {
    let label: String
    let symbol: String
    let tint: Color

    static func of(_ clip: DashcamServerClip, uploadingID: String? = nil) -> DashcamClipStatus {
        if clip.failed {
            let reason = clip.destinations.values.first { $0.state == "failed" }?.error ?? clip.phoneError
            return .init(label: reason.map { "Failed: \($0)" } ?? "Failed", symbol: "exclamationmark.triangle.fill", tint: JcTheme.danger)
        }
        if clip.uploaded { return .init(label: "Uploaded", symbol: "checkmark.icloud.fill", tint: JcTheme.success) }
        if clip.id == uploadingID || clip.uploading {
            return .init(label: "Uploading", symbol: "arrow.up.circle.fill", tint: JcTheme.accent)
        }
        switch clip.phoneState {
        case "local": return .init(label: "On phone", symbol: "iphone", tint: JcTheme.amber)
        case "downloading", "queued": return .init(label: "Downloading", symbol: "arrow.down.circle", tint: JcTheme.accent)
        default: break
        }
        if clip.onCamera { return .init(label: "On camera", symbol: "sdcard", tint: JcTheme.muted) }
        return .init(label: "Gone from camera", symbol: "sdcard.fill", tint: JcTheme.muted)
    }
}

@MainActor
final class DashcamLibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, events, photos, toUpload, failed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .events: return "Events"
            case .photos: return "Photos"
            case .toUpload: return "To upload"
            case .failed: return "Failed"
            }
        }
        var apiFilter: DashcamAPI.ClipFilter {
            switch self {
            case .all: return .init()
            case .events: return .init(kind: .event)
            case .photos: return .init(kind: .photo)
            case .toUpload: return .init(state: "pending_upload")
            case .failed: return .init(state: "failed")
            }
        }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let clips: [DashcamServerClip]
    }

    @Published var filter: Filter = .all { didSet { if filter != oldValue { Task { await reload() } } } }
    @Published var lens: DashcamLens? = nil { didSet { if lens != oldValue { Task { await reload() } } } }
    @Published private(set) var clips: [DashcamServerClip] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var next: String?
    var api = DashcamAPI()

    var canLoadMore: Bool { next != nil && !loading }

    func reload() async {
        next = nil
        await load(reset: true)
    }

    func loadMore() async {
        guard canLoadMore else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        var f = filter.apiFilter
        f.lens = lens
        do {
            let page = try await api.clips(f, cursor: reset ? nil : next, limit: 60)
            clips = reset ? page.clips : clips + page.clips.filter { c in !clips.contains { $0.id == c.id } }
            next = page.next
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func replace(_ clip: DashcamServerClip) {
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = clip }
    }

    var sections: [Section] { Self.sections(clips, calendar: .current, now: Date()) }

    /// Clips grouped by local day, newest first: "Today", "Yesterday", then the date.
    static func sections(_ clips: [DashcamServerClip], calendar: Calendar, now: Date) -> [Section] {
        let grouped = Dictionary(grouping: clips) { calendar.startOfDay(for: $0.start) }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, MMM d"
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) { title = "Today" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { title = "Yesterday" }
            else { title = f.string(from: day) }
            return Section(id: ISO8601DateFormatter().string(from: day), title: title,
                           clips: grouped[day, default: []].sorted { $0.start > $1.start })
        }
    }
}

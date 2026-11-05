import SwiftUI

// The dashcam sync Live Activity's views: the Lock Screen and the Dynamic
// Island's regions. Plain SwiftUI in Copilot/Shared so the widget draws them
// (`DashcamSyncActivity`) and the app's render tests can too.
//
// Black and white like the workout and Claude activities (2026-11-04, his
// call: the old one clipped its percentage and was "wayyy too squished"): the
// car in black on a white disc, a white bar per transfer on a grey well, small
// grey labels. Clip file names become "Rear · 11:19 PM".

/// "2025_10_25_23_19_20_b.ts" → "Rear · 11:19 PM" today, "Rear · Oct 25" before; anything else, its name without the extension.
struct DashcamClipLabel {
    static func text(_ name: String, now: Date = Date()) -> String {
        let stem = (name as NSString).deletingPathExtension
        let pattern = #"(\d{4})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})[_-]?(\d{2})(?:[_-]?([A-Za-z]))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { return stem }
        func part(_ i: Int) -> String? {
            Range(m.range(at: i), in: stem).map { String(stem[$0]) }
        }
        var c = DateComponents()
        c.year = part(1).flatMap(Int.init); c.month = part(2).flatMap(Int.init); c.day = part(3).flatMap(Int.init)
        c.hour = part(4).flatMap(Int.init); c.minute = part(5).flatMap(Int.init); c.second = part(6).flatMap(Int.init)
        guard let date = Calendar.current.date(from: c) else { return stem }
        let side: String? = switch part(7)?.lowercased() {
        case "b", "r": "Rear"
        case "f": "Front"
        default: nil
        }
        // Short enough to sit beside the title: today's clips by time, older ones by day.
        let when = Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
        return [side, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One transfer: camera → phone, or phone → cloud.
struct DashcamLane: Identifiable, Equatable {
    enum Kind { case download, upload }
    let kind: Kind
    let detail: String
    let fraction: Double

    var id: Kind { kind }
    var title: String { kind == .download ? "From dashcam" : "To the cloud" }
    var symbol: String { kind == .download ? "arrow.down" : "arrow.up" }
    var percent: String { "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%" }

    static func lanes(_ s: DashcamSyncAttributes.ContentState) -> [DashcamLane] {
        var out: [DashcamLane] = []
        if !s.downloadName.isEmpty {
            out.append(DashcamLane(kind: .download, detail: DashcamClipLabel.text(s.downloadName),
                                   fraction: s.downloadFraction))
        }
        if s.uploading {
            let waiting = max(0, s.toUpload - 1)
            out.append(DashcamLane(kind: .upload, detail: waiting > 0 ? "\(waiting) waiting" : "",
                                   fraction: s.uploadFraction))
        }
        return out
    }
}

extension DashcamSyncAttributes.ContentState {
    /// Clips not in the cloud yet: the ones still on the camera plus the ones waiting to go up.
    var clipsToGo: Int { (downloadName.isEmpty ? 0 : max(1, toDownload)) + (uploading ? max(1, toUpload) : 0) }
    /// The transfer the collapsed island follows: the camera's while it is on its Wi‑Fi, else the upload.
    var leadFraction: Double { min(1, max(0, downloadName.isEmpty ? uploadFraction : downloadFraction)) }
    var leadSymbol: String {
        !downloadName.isEmpty && uploading ? "arrow.up.arrow.down" : uploading ? "icloud.and.arrow.up" : "arrow.down.circle"
    }
}

/// A transfer: its arrow, title and detail, the percentage, and a white bar on a grey well.
struct DashcamLaneRow: View {
    let lane: DashcamLane
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: lane.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WorkoutLA.secondary)
                    .frame(width: 12)
                Text(lane.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WorkoutLA.primary)
                    .layoutPriority(1)
                Text(lane.detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkoutLA.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(lane.percent)
                    .font(WorkoutLA.figures(15, .semibold))
                    .foregroundStyle(WorkoutLA.primary)
                    .fixedSize()
            }
            .lineLimit(1)
            DashcamBar(fraction: lane.fraction)
        }
    }
}

/// A thin white bar on a grey well.
struct DashcamBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(WorkoutLA.well)
                Capsule().fill(WorkoutLA.primary)
                    .frame(width: max(4, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Lock Screen

struct DashcamLockScreenView: View {
    let cameraName: String
    let state: DashcamSyncAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WorkoutSportDisc(symbol: "car.rear.fill", size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cameraName).font(.system(size: 16, weight: .semibold)).foregroundStyle(WorkoutLA.primary)
                    Text("Syncing").font(.system(size: 13, weight: .medium)).foregroundStyle(WorkoutLA.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                DashcamClipsLeft(count: state.clipsToGo, size: 32)
            }
            VStack(spacing: 10) {
                ForEach(DashcamLane.lanes(state)) { DashcamLaneRow(lane: $0) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

// MARK: - Dynamic Island

/// Expanded, leading: the disc and the camera. The region beside the camera is
/// narrow on a real island (the name truncated to "HUAX…"): the widget gives it
/// width first and the name may shrink a little before it truncates.
struct DashcamIslandLeading: View {
    let cameraName: String

    var body: some View {
        HStack(spacing: 6) {
            WorkoutSportDisc(symbol: "car.rear.fill", size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(cameraName).font(.system(size: 14, weight: .semibold)).foregroundStyle(WorkoutLA.primary)
                    .minimumScaleFactor(0.75)
                Text("Syncing").font(.system(size: 12, weight: .medium)).foregroundStyle(WorkoutLA.secondary)
            }
            .lineLimit(1)
        }
        .padding(.leading, 2)
    }
}

/// How many clips are still to go, as a big figure: "232" beside (or over) "clips left".
struct DashcamClipsLeft: View {
    let count: Int
    var size: CGFloat = 34
    /// The label under the figure rather than beside it: the island's trailing region is narrow.
    var stacked = false

    private var label: some View {
        Text(count == 1 ? (stacked ? "clip left" : "clip\nleft") : (stacked ? "clips left" : "clips\nleft"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkoutLA.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize()
    }

    private var figure: some View {
        Text("\(count)").font(WorkoutLA.figures(size, .semibold)).foregroundStyle(WorkoutLA.primary)
            .lineLimit(1).fixedSize()
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .trailing, spacing: -3) { figure; label }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) { figure; label }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Expanded, trailing: how many clips are still to go.
struct DashcamIslandTrailing: View {
    let state: DashcamSyncAttributes.ContentState

    var body: some View {
        DashcamClipsLeft(count: state.clipsToGo, size: 24, stacked: true)
            .padding(.trailing, 4)
    }
}

/// Expanded, bottom: a row per transfer. Tight: the expanded island stops at
/// ~160 pt and cut the second bar off on a real island.
struct DashcamIslandBottom: View {
    let state: DashcamSyncAttributes.ContentState

    var body: some View {
        VStack(spacing: 7) {
            ForEach(DashcamLane.lanes(state)) { DashcamLaneRow(lane: $0, compact: true) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

/// Collapsed, leading: what is moving.
struct DashcamCompactLeading: View {
    let state: DashcamSyncAttributes.ContentState

    var body: some View {
        Image(systemName: state.leadSymbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WorkoutLA.primary)
            .padding(.leading, 2)
    }
}

/// Collapsed, trailing: the lead transfer's percentage, in a box wide enough for "100%".
struct DashcamCompactTrailing: View {
    let state: DashcamSyncAttributes.ContentState

    var body: some View {
        Text("\(Int((state.leadFraction * 100).rounded(.down)))%")
            .font(WorkoutLA.figures(14, .semibold))
            .foregroundStyle(WorkoutLA.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 2)
    }
}

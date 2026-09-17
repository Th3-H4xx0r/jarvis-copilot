import SwiftUI

/// The day in one number — Body battery — with the four parts that made it and
/// a couple of sentences about them.
///
/// Every figure was computed on the server; the sentences are the only
/// generated part. One footer line says when it was last read and offers to
/// read it again — nothing else qualifies the number, because a card that
/// explains itself three times is a card nobody finishes.
struct HealthScoreCard: View {
    let scores: HealthScores?
    let lastRefreshed: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        CardGroup(HealthScores.batteryName) {
            if let scores {
                Row(minHeight: 108) {
                    VStack(alignment: .leading, spacing: 20) {
                        headline(scores)
                        parts(scores)
                    }
                    .padding(.vertical, 6)
                }
                if !scores.analysis.isEmpty {
                    RowDivider()
                    Row {
                        Text(scores.analysis)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
                RowDivider()
                Row {
                    HStack {
                        Text(updatedText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        refreshButton
                    }
                }
            } else {
                Row(minHeight: 84) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isRefreshing ? "Scoring this day…" : "No score for this day yet")
                                .foregroundStyle(.secondary)
                            Text("The server scores each day from the ring's readings.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 12)
                        refreshButton
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Pieces

    private func headline(_ scores: HealthScores) -> some View {
        HStack(alignment: .center, spacing: 16) {
            gauge(scores.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(scores.health.value.map(String.init) ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(scores.health.band)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func gauge(_ part: ScorePart) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(Double(part.value ?? 0) / 100))
                .stroke(tint(part), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 54, height: 54)
        // The band is written beside it, so the ring is decoration for a value
        // that is already spelled out (accessibility.md › Color and effects).
        .accessibilityHidden(true)
    }

    private func parts(_ scores: HealthScores) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(scores.parts, id: \.name) { part in
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(part.score.value.map(String.init) ?? "—")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(part.score.value == nil ? Color.secondary : tint(part.score))
                        .accessibilityLabel(part.score.value == nil
                                            ? "\(part.name), building baseline"
                                            : "\(part.name) \(part.score.value!)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRefreshing)
        .accessibilityLabel("Score this day again")
    }

    /// When the server last scored this day, in the phone's own words.
    private var updatedText: String {
        if isRefreshing { return "Reading the ring…" }
        guard let lastRefreshed else { return "Not read yet" }
        let seconds = Date().timeIntervalSince(lastRefreshed)
        if seconds < 90 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "Updated \(Int(seconds / 3600))h ago" }
        return "Updated \(Int(seconds / 86_400))d ago"
    }

    /// Band colours from the app's own tokens — never a per-file literal.
    private func tint(_ part: ScorePart) -> Color {
        switch part.band {
        case "Excellent": return JcTheme.accent
        case "Good": return JcTheme.accentAlt
        case "Fair": return JcTheme.amber
        case "Low": return .orange
        default: return .secondary
        }
    }
}

extension HealthScores {
    /// What the overall score is called on screen.
    static let batteryName = "Body battery"
}

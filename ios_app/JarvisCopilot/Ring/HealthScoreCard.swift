import SwiftUI

/// The day in one number — Body battery — with the four parts that made it and
/// a sentence or two about them.
///
/// Every figure was computed on the server; the sentences are the only
/// generated part, which is why they are labelled as written and can be asked
/// for again (`generative-ai.md › Best practices`).
struct HealthScoreCard: View {
    let scores: HealthScores?
    let stale: Bool
    /// The server scored older data, as opposed to this phone holding an old copy.
    let ringUnreachable: Bool
    let age: TimeInterval?
    let isRefreshing: Bool
    let onAsk: () -> Void
    let onRerun: () -> Void

    var body: some View {
        CardGroup(HealthScores.batteryName) {
            if let scores {
                Row(minHeight: 96) {
                    VStack(alignment: .leading, spacing: 16) {
                        headline(scores)
                        parts(scores)
                    }
                }
                analysisRows(scores)
                if !footnote(scores).isEmpty {
                    RowDivider()
                    Row { caption(footnote(scores)) }
                }
            } else {
                Row(minHeight: 72) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isRefreshing ? "Scoring this day…" : "No score for this day yet")
                            .foregroundStyle(.secondary)
                        Text("The server scores each day from the ring's own readings.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Headline

    /// The gauge, the number and its band, side by side and baseline-aligned.
    private func headline(_ scores: HealthScores) -> some View {
        HStack(alignment: .center, spacing: 14) {
            gauge(scores.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(scores.health.value.map(String.init) ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(scores.health.band)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRefreshing { ProgressView().controlSize(.mini) }
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
        .frame(width: 52, height: 52)
        // The band is the text beside it; the ring is not carrying the meaning
        // on its own (accessibility.md › Color and effects).
        .accessibilityHidden(true)
    }

    /// The four parts on one aligned row, in the same idiom as the ring's own
    /// metric pills — `layout.md › Align components with one another`.
    private func parts(_ scores: HealthScores) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(scores.parts, id: \.name) { part in
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let value = part.score.value {
                        Text("\(value)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint(part.score))
                    } else {
                        Text("—")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(part.score.missing.contains("baseline")
                                                ? "building baseline" : "not measured")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: The written part

    @ViewBuilder private func analysisRows(_ scores: HealthScores) -> some View {
        if !scores.analysis.isEmpty {
            RowDivider()
            Row {
                VStack(alignment: .leading, spacing: 10) {
                    Text(scores.analysis)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        // Say what was written rather than computed, and by what.
                        Text(scores.model.isEmpty ? "Written from the numbers above"
                                                  : "Written by \(scores.model)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button("Ask Jarvis", action: onAsk)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button {
                            onRerun()
                        } label: {
                            Label("Again", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Write it again")
                    }
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }

    /// One line for everything qualifying the number, rather than a row each.
    private func footnote(_ scores: HealthScores) -> String {
        var parts: [String] = []
        if !scores.missingNote.isEmpty { parts.append(scores.missingNote) }
        if stale { parts.append(staleNote) }
        return parts.joined(separator: " ")
    }

    private var staleNote: String {
        let when = age.map(ago) ?? ""
        if ringUnreachable {
            return when.isEmpty
                ? "Scored from earlier readings — the ring did not answer this run."
                : "Scored from earlier readings (\(when)) — the ring did not answer this run."
        }
        return when.isEmpty ? "Pull to refresh for the latest." : "Last read \(when)."
    }

    private func ago(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let minutes = max(1, Int(seconds / 60) % 60)
        return hours > 0 ? "\(hours)h \(minutes)m ago" : "\(minutes)m ago"
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

    /// Which parts could not be scored, said plainly.
    var missingNote: String {
        let names = parts.filter { $0.score.isMissing }.map { $0.name.lowercased() }
        guard !names.isEmpty else { return "" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "No \(list) to score today, so the rest carries the number."
    }
}

import SwiftUI

/// The day in one number, with the four parts that made it and a sentence or
/// two about them.
///
/// Every figure here was computed on the server; the sentences are the only
/// generated part, and they are written over numbers already decided.
struct HealthScoreCard: View {
    let scores: HealthScores?
    let stale: Bool
    let age: TimeInterval?
    let isRefreshing: Bool
    let onAsk: () -> Void

    var body: some View {
        CardGroup("Health") {
            if let scores {
                Row(minHeight: 132) {
                    HStack(alignment: .top, spacing: 18) {
                        gauge(scores.health)
                        VStack(alignment: .leading, spacing: 10) {
                            parts(scores)
                            if !scores.analysis.isEmpty {
                                Text(scores.analysis)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !scores.missingNote.isEmpty {
                    RowDivider()
                    Row { caption(scores.missingNote) }
                }
                if stale {
                    RowDivider()
                    Row { caption(staleNote) }
                }
                RowDivider()
                Row {
                    HStack {
                        Button("Ask Jarvis", action: onAsk).buttonStyle(.plain).foregroundStyle(JcTheme.accent)
                        Spacer()
                        if isRefreshing { ProgressView().controlSize(.mini) }
                    }
                    .font(.subheadline)
                }
            } else {
                Row {
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

    // MARK: Pieces

    private func gauge(_ part: ScorePart) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(Double(part.value ?? 0) / 100))
                    .stroke(tint(part), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(part.value.map(String.init) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 86, height: 86)
            Text(part.band).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func parts(_ scores: HealthScores) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(scores.parts, id: \.name) { part in
                HStack(spacing: 6) {
                    Text(part.name).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let value = part.score.value {
                        Text("\(value)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint(part.score))
                    } else {
                        Text(part.score.missing.contains("baseline") ? "building baseline" : "—")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }

    private var staleNote: String {
        guard let age, age > 60 else { return "The ring could not be reached, so these are older readings." }
        let hours = Int(age / 3600)
        let minutes = Int(age / 60) % 60
        let when = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "From \(when) ago — the ring could not be reached since."
    }

    private func tint(_ part: ScorePart) -> Color {
        switch part.band {
        case "Excellent": return Color(red: 0.29, green: 0.82, blue: 0.49)
        case "Good": return JcTheme.accent
        case "Fair": return JcTheme.amber
        case "Low": return .orange
        default: return .secondary
        }
    }
}

extension HealthScores {
    /// Which parts could not be scored, said plainly.
    var missingNote: String {
        let names = parts.filter { $0.score.isMissing }.map { $0.name.lowercased() }
        guard !names.isEmpty else { return "" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "No \(list) to score today, so the rest carries the number."
    }
}

import SwiftUI

/// GitHub's contribution calendar: one column per week (oldest on the left),
/// Sunday on top, each day in the accent at GitHub's own quartile.
///
/// Drawn in one `Canvas` and sized by aspect ratio, so a year of 53 columns
/// fits the card's width without a scroll view.
struct ContributionGrid: View {
    let activity: GitHubActivity
    /// The most recent weeks to draw; nil draws all of them.
    var weeks: Int? = nil

    /// Gap between cells, as a fraction of a cell.
    private static let gap: CGFloat = 0.24

    private var columns: [[ContributionDay]] {
        weeks.map { activity.recentWeeks($0) } ?? activity.weeks
    }

    var body: some View {
        let columns = self.columns
        let count = CGFloat(max(1, columns.count))
        let ratio = (count + Self.gap * (count - 1)) / (7 + Self.gap * 6)
        Canvas { context, size in
            let cell = size.width / (count + Self.gap * (count - 1))
            let step = cell * (1 + Self.gap)
            for (x, week) in columns.enumerated() {
                for day in week {
                    let rect = CGRect(x: CGFloat(x) * step, y: CGFloat(day.weekday) * step,
                                      width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.24),
                                 with: .color(Self.color(level: day.level)))
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("\(activity.total) contributions in the last year")
    }

    static func color(level: Int) -> Color {
        let strength: [Double] = [0.30, 0.50, 0.74, 1.0]
        guard level > 0 else { return .white.opacity(0.07) }
        return JcTheme.accent.opacity(strength[min(level, 4) - 1])
    }
}

/// The GitHub header up close: who, repos and stars, the year's total and grid.
struct GitHubActivityCard: View {
    let activity: GitHubActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if !activity.login.isEmpty {
                    Text("@\(activity.login)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                }
                Spacer(minLength: 0)
                if let repos = activity.repos { figure("\(repos)", repos == 1 ? "repo" : "repos") }
                if let stars = activity.stars { figure("\(stars)", stars == 1 ? "star" : "stars") }
            }
            ContributionGrid(activity: activity)
            HStack(spacing: 4) {
                Text("\(activity.total) contributions in the last year")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                Spacer(minLength: 8)
                Text("Less").font(.system(size: 10)).foregroundStyle(JcTheme.muted)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ContributionGrid.color(level: level))
                        .frame(width: 9, height: 9)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(JcTheme.muted)
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private func figure(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(JcTheme.text)
            Text(label).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
        }
    }
}

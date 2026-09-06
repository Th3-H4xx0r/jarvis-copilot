import SwiftUI

// MARK: - System health

/// CPU / RAM / Disk as labelled progress bars. RAM and Disk carry a
/// "used / total" byte subtitle; CPU shows just the percent. A metric the server
/// didn't report is skipped rather than drawn at zero.
struct InsightsHealthCard: View {
    let health: SystemHealth

    private var rows: [(label: String, percent: Double, subtitle: String)] {
        var out: [(String, Double, String)] = []
        if let cpu = health.cpuPercent { out.append(("CPU", cpu, "")) }
        if let memory = health.memoryPercent { out.append(("RAM", memory, health.memoryLabel)) }
        if let disk = health.diskPercent { out.append(("Disk", disk, health.diskLabel)) }
        return out
    }

    var body: some View {
        GlassCard {
            if rows.isEmpty {
                InsightsEmptyBlock(symbol: "speedometer", text: "Host metrics unavailable.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Current VPS resource usage")
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                    ForEach(rows, id: \.label) { row in
                        InsightsMetricBar(label: row.label, percent: row.percent,
                                          subtitle: row.subtitle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One health metric: name + optional byte subtitle + percent, over an 8pt bar.
struct InsightsMetricBar: View {
    let label: String
    /// 0…100.
    let percent: Double
    let subtitle: String

    private var tint: Color { Color(tone: InsightsUI.metricTone(percent)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                if subtitle.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(InsightsUI.metricPercentText(percent))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(JcTheme.glassFill)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * min(max(percent / 100, 0), 1)))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - LLM Wiki

/// Knowledge-base observability: an availability chip, an explanatory note, and
/// a two-up grid of key/value tiles.
struct InsightsWikiCard: View {
    let wiki: WikiStatus

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let badge = InsightsUI.wikiBadge(wiki)
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("Knowledge-base observability")
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                    Spacer(minLength: 0)
                    StatusPill(badge.label, color: Color(tone: badge.tone), dense: true)
                }
                Text(InsightsUI.wikiNote(wiki))
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(InsightsUI.wikiTiles(wiki), id: \.label) { tile in
                        InsightsKeyValueTile(label: tile.label, value: tile.value)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A compact key-over-value chip.
struct InsightsKeyValueTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(JcTheme.muted)
            Text(value)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Headline stats

/// Sessions / Messages / Tokens / Est. cost as a 2-column grid of stat tiles.
struct InsightsStatGrid: View {
    let overview: InsightsOverview

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var tiles: [(label: String, value: String, symbol: String, tone: MoreTone)] {
        [("Sessions", Insights.formatTokenCount(overview.totalSessions), "bubble.left.and.bubble.right", .cyan),
         ("Messages", Insights.formatTokenCount(overview.totalMessages), "number", .blue),
         ("Tokens", Insights.formatTokensCompact(overview.totalTokens), "memorychip", .accent),
         ("Est. cost", Insights.formatCost(overview.totalCost), "dollarsign", .success)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(tiles, id: \.label) { tile in
                InsightsStatTile(label: tile.label, value: tile.value,
                                 symbol: tile.symbol, tone: tile.tone)
            }
        }
    }
}

/// Tinted icon chip over a big number and a muted caption.
struct InsightsStatTile: View {
    let label: String
    let value: String
    let symbol: String
    let tone: MoreTone

    var body: some View {
        let tint = Color(tone: tone)
        // `blur: false` — a grid of blurred cards is the one place the material
        // actually costs frames.
        GlassCard(padding: 14, blur: false) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.4)
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(label.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Token breakdown

/// Input / Output / Total from the overview totals.
struct InsightsTokenBreakdownCard: View {
    let overview: InsightsOverview

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                row("Input tokens", Insights.formatTokensCompact(overview.totalInputTokens))
                divider
                row("Output tokens", Insights.formatTokensCompact(overview.totalOutputTokens))
                divider
                row("Total", Insights.formatTokensCompact(overview.totalTokens), bold: true)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.vertical, 9)
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13.5, weight: bold ? .bold : .medium))
                .foregroundStyle(bold ? JcTheme.text : JcTheme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14.5, weight: bold ? .bold : .semibold))
                .foregroundStyle(JcTheme.text)
        }
    }
}

// MARK: - By model

/// Per-model breakdown: name over "sessions · tokens · share", cost as a chip.
struct InsightsModelsCard: View {
    let models: [ModelStat]

    var body: some View {
        GlassCard {
            if models.isEmpty {
                InsightsEmptyBlock(symbol: "square.stack.3d.up",
                                   text: "No model usage in this period.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                        }
                        InsightsModelRow(model: model)
                    }
                }
            }
        }
    }
}

struct InsightsModelRow: View {
    let model: ModelStat

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.model)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(InsightsUI.modelSubtitle(model))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            StatusPill(Insights.formatCost(model.cost), color: JcTheme.cyan, dense: true)
        }
        .padding(.vertical, 10)
    }
}

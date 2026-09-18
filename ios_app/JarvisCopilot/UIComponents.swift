import SwiftUI

/// A grouped section, sized and spaced like an inset-grouped list rather than a dense
/// stack: rows carry their own height and padding, separators are inset from the left.
///
/// The header, the glass, the radius and the 16pt page margin are the Insights
/// screen's — `SectionHeader` over a card, which is the one register the whole
/// app uses now. Anything built from `CardGroup` inherits it; a screen that
/// hand-rolls its own header is the thing to fix, not this.
struct CardGroup<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { SectionHeader(title) }
            VStack(spacing: 0) { content }
                .background(JcTheme.glassFill,
                            in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                    .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
        // A touch wider than the 16pt the rest of the app uses: these cards are
        // dense, and the extra margin is what stops them reading as a slab.
        .padding(.horizontal, 20)
    }
}

/// The empty state that belongs INSIDE a card: an icon and a line, quiet and
/// centred, instead of a bare sentence where the content should be. Lifted out
/// of Insights, which is where the app's look is defined now.
struct CardEmptyBlock: View {
    let symbol: String
    let text: String

    init(symbol: String = "tray", text: String) {
        self.symbol = symbol
        self.text = text
    }

    /// The common case, where the default tray icon is the right one.
    init(_ text: String, symbol: String = "tray") {
        self.init(symbol: symbol, text: text)
    }

    var body: some View {
        HStack(spacing: 8) {
            JcIcon(symbol).font(.system(size: 16)).foregroundStyle(JcTheme.muted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// One row. 48pt is a touch taller than UIKit's 44 so the controls breathe.
struct Row<Content: View>: View {
    var minHeight: CGFloat = 48
    @ViewBuilder var content: Content

    init(minHeight: CGFloat = 48, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        content
            // Vertical padding, not just `minHeight`: a row taller than the
            // minimum — a two-line caption, a stepper with a note under it —
            // got none at all, so its last line sat flush against the card's
            // bottom edge and looked clipped.
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

/// Hairline separator, inset from the leading edge the way system lists do it.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// A circular command button with its name underneath, like the action row on a
/// contact card. Liquid glass, tinted with its colour while the command is active.
/// A capsule action: icon and word together, on one line that scrolls.
///
/// Replaces a grid of labelled circles, which wrapped to a second row as soon
/// as a ring reported more than three measurements and clipped at the screen
/// edge. A row that scrolls cannot wrap, and a label beside its icon reads at a
/// glance without a caption underneath (`buttons.md` › "Avoid using labels to
/// introduce square buttons").
struct ActionChip: View {
    let title: String
    let icon: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                JcIcon(icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.white : tint)
            .padding(.horizontal, 14)
            // 44pt tall: the platform's minimum target, met by the control
            // itself rather than by the space around it.
            .frame(height: 44)
            .jcLiquidGlass(in: Capsule(), tint: isOn ? tint.opacity(0.75) : .clear)
        }
        .buttonStyle(.plain)
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                JcIcon(icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? .white : tint)
                    .frame(width: 56, height: 56)
                    .jcLiquidGlass(in: Circle(), tint: isOn ? tint.opacity(0.6) : .clear)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

/// A compact metric pill: tinted glyph, label above value. Used where a reading has to
/// sit over the 3D scene rather than in a row.
struct MetricPill: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color

    var body: some View {
        HStack(spacing: 9) {
            JcIcon(icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: -1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

/// What a device card shows instead of a signal reading when the device is remembered but
/// out of reach — so a card never claims a link it doesn't have.
///
/// A remembered board or ring is surfaced into its manager's scan list with an RSSI of 0,
/// which used to read as "Known" or even "Wi‑Fi" on the card while a second row underneath
/// said "Not found". One card, one honest status. When it was last in range goes in
/// the card's corner (`lastSeenCorner`), not beside the pill.
struct DisconnectedPill: View {
    var body: some View {
        MetricPill(icon: "antenna.radiowaves.left.and.right.slash", label: "Status",
                   value: "Disconnected", tint: .secondary)
    }

    /// "last seen 22h ago", or nil when we have never had it in hand. Within the
    /// last minute it is "just now": the formatter called a moment ago "in 0s".
    static func lastSeenNote(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if now.timeIntervalSince(date) < 60 { return "last seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "last seen \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

extension View {
    /// A device card's "last seen …", in its bottom-right corner — shown while the
    /// card says the device is disconnected.
    func lastSeenCorner(_ date: Date?, visible: Bool) -> some View {
        overlay(alignment: .bottomTrailing) {
            if visible, let note = DisconnectedPill.lastSeenNote(date) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Shared formatting

/// Thresholds are physical, so they stay in Celsius whichever unit is displayed.
/// Lifted from the app's own `tempColorModeArrTCArr` = [0, 45, 55].
func temperatureTint(_ celsius: Int) -> Color? {
    switch celsius {
    case ..<45:   return nil                                   // unremarkable
    case 45..<55: return .orange
    default:      return Color(red: 1.0, green: 0.31, blue: 0.27)
    }
}

func batteryTint(_ percent: Int) -> Color? {
    switch percent {
    case ..<15:   return Color(red: 1.0, green: 0.31, blue: 0.27)
    case 15..<35: return .orange
    default:      return nil
    }
}

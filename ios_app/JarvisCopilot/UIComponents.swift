import SwiftUI

/// A grouped section, sized and spaced like an inset-grouped list rather than a dense
/// stack: rows carry their own height and padding, separators are inset from the left.
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
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            VStack(spacing: 0) { content }
                .background(Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
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
/// contact card. Fills with its tint while the command is active.
struct ActionButton: View {
    let title: String
    let icon: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? .white : tint)
                    .frame(width: 56, height: 56)
                    .background(isOn ? tint : tint.opacity(0.15), in: Circle())
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
            Image(systemName: icon)
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

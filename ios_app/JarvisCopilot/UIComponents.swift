import SwiftUI
import UIKit

/// A grouped section, sized and spaced like an inset-grouped list rather than a dense
/// stack: rows carry their own height and padding, separators are inset from the left.
///
/// Built from the app's one set of page pieces (`JcUnified.swift`): a
/// `JcSectionLabel` over a `JcCard`, at the page inset. Anything built from
/// `CardGroup` inherits it; a screen that hand-rolls its own header is the thing
/// to fix, not this.
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
            // `first`: the screen's own stack spacing already sits above the group.
            if let title { JcSectionLabel(title, first: true) }
            // Rows bring their own insets and run their separators to the edge.
            // The accent is the on-state: a switch in a card is teal, as in Settings.
            JcCard(padding: 0) { content }
                .tint(JcTheme.accent)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, JcUnified.pageInset)
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
        // Cards hold it at no padding: a long message ran to the card's edge (the dashcam player's "Not on
        // the phone yet…", 2026-11-04). The row inset keeps it inside.
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
            .foregroundStyle(isOn ? JcButton.label : tint)
            .padding(.horizontal, 14)
            // 44pt tall: the platform's minimum target, met by the control
            // itself rather than by the space around it.
            .frame(height: 44)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous), selected: isOn)
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
                    .foregroundStyle(isOn ? JcButton.label : tint)
                    .frame(width: 56, height: 56)
                    .jcButtonSurface(in: Circle(), selected: isOn)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

/// A compact metric pill: glyph, label above value. Used where a reading has to
/// sit over the 3D scene rather than in a row.
struct MetricPill: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color

    /// The glyph wears its reading's colour (2026-11-04, his ask: "bring the color back to
    /// the icons"); a muted tint is a quiet grey glyph on grey.
    private var glyph: Color { tint }
    private var muted: Bool { tint == JcTheme.muted }

    var body: some View {
        HStack(spacing: 9) {
            JcIcon(icon, size: 13)
                .foregroundStyle(glyph)
                .frame(width: 26, height: 26)
                .background(muted ? Color.white.opacity(0.08) : tint.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: -1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
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
                   value: "Disconnected", tint: JcTheme.muted)
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
                    .foregroundStyle(JcTheme.muted.opacity(0.7))
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
    case 45..<55: return JcTheme.amber
    default:      return JcTheme.danger
    }
}

func batteryTint(_ percent: Int) -> Color? {
    switch percent {
    case ..<15:   return JcTheme.danger
    case 15..<35: return JcTheme.amber
    default:      return nil
    }
}

/// A card in its own window above everything in the app, sheets included, while it is shown.
/// Only on the phone's own screen, never the car's.
@MainActor
final class OverlayWindow {
    private var window: UIWindow?
    private let level: UIWindow.Level

    init(level: UIWindow.Level = .alert + 1) { self.level = level }

    /// Puts `content` up, unless it already is.
    func show(_ content: () -> some View) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let made = UIWindow(windowScene: scene)
        made.windowLevel = level
        made.backgroundColor = .clear
        made.rootViewController = host
        made.isHidden = false
        window = made
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

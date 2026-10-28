import SwiftUI
import UIKit

/// A pulse spreading out from the orb and fading, about every two seconds, the way
/// Music Recognition's symbol pulses in the Dynamic Island.
///
/// A Live Activity runs no SF Symbol effect and no SwiftUI animation (probed in the
/// iOS 27 simulator, 2026-10-27: pulse, rotate, breathe and variable colour all froze);
/// the system keeps only its own timers ticking. So the pulse is eight
/// `Text(timerInterval:)` timers, each in a font (`JarvisWidget/Fonts/JCPulse<k>.otf`,
/// made by `scripts/make_pulse_fonts.py`) whose even digits draw ring band k of the
/// ripple and whose odd digits draw nothing: each band shows for a second and hides
/// for a second. Started an eighth of a second apart, the bands come on inner to
/// outer, then go off in the same order — a ring growing out of the orb and fading,
/// in eight steps a second. The fonts draw only the seconds digit (any digit followed
/// by another, and the colon, are blanks of no width), and each timer runs from when
/// the state began, so a new line of words doesn't restart it.
struct JarvisPulse: View {
    var color: Color
    /// The ripple's outer diameter; it starts at 60% of it, the orb's edge.
    var size: CGFloat
    /// When the state began (Unix seconds; 0 = now).
    var since: Double

    static let bands = 8
    /// The orb's share of the badge: the ripple starts at its edge.
    static let orbShare: CGFloat = 0.6

    var body: some View {
        if Self.fontsReady {
            let from = since > 0 ? Date(timeIntervalSince1970: since) : Date()
            ZStack {
                ForEach(0..<Self.bands, id: \.self) { band in
                    let start = from.addingTimeInterval(Double(band) / Double(Self.bands))
                    // The font blanks every digit but the seconds (calt), so the timer is
                    // one ring wide whatever it reads.
                    Text(timerInterval: start...start.addingTimeInterval(3600), countsDown: false)
                        .font(.custom("JCPulse\(band)", fixedSize: size))
                        // Fading as it spreads.
                        .foregroundStyle(color.opacity(0.85 - 0.75 * Double(band) / Double(Self.bands - 1)))
                        .lineLimit(1)
                        .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// The fonts ship in the widget extension only: anywhere else (the app's render
    /// tests) the timers would draw as plain digits, so nothing is drawn.
    static let fontsReady = UIFont(name: "JCPulse0", size: 10) != nil

    /// The pulse's colour for a voice state; nil at rest (no pulse).
    static func color(_ state: String) -> Color? {
        switch state {
        case "listening", "speaking": return jcStateColor(state)
        case "thinking": return .white
        default: return nil
        }
    }
}

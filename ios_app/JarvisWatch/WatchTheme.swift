import SwiftUI
import UIKit

/// Shared styling for the watch app, mirroring the mobile dark-glass look with
/// its cyan accent: the Inter typeface and an ambient near-black backdrop with
/// faint aurora glows.
enum JcWatch {
    // Text
    static let text = Color(red: 0.93, green: 0.94, blue: 0.97)
    static let muted = Color(red: 0.72, green: 0.75, blue: 0.81)
    /// The app's accent (`JcAccent`), for anything live or selected.
    static let accent = JcAccent.color

    /// Ambient backdrop: near-black with a couple of very faint colour washes,
    /// matching the mobile voice screen (kept subtle for OLED battery).
    static var background: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.05, blue: 0.07), .black],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [JcAccent.deep.opacity(0.16), .clear],
                center: .topLeading, startRadius: 2, endRadius: 160)
            RadialGradient(
                colors: [JcAccent.color.opacity(0.08), .clear],
                center: .bottomTrailing, startRadius: 2, endRadius: 170)
        }
        .ignoresSafeArea()
    }
}

extension Font {
    /// App typeface = Inter (registered at launch in JarvisWatchApp). Inter's
    /// Medium/SemiBold ship under their OWN family names ("Inter Medium" etc.),
    /// so `.custom("Inter").weight(.medium)` would silently fall back to Regular.
    /// Reference each face by its exact PostScript name instead.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Inter-Bold"
        case .semibold: face = "Inter-SemiBold"
        case .medium: face = "Inter-Medium"
        default: face = "Inter-Regular"
        }
        return .custom(face, size: size)
    }
}

// MARK: - Icons (Phosphor)

/// One icon from the bundled Phosphor set (MIT), drawn as a template image so it takes
/// the surrounding foreground colour. `size` is the icon's height in points — SF Symbols
/// took their size from the font, asset images can't, so each call site names it.
struct JcIcon: View {
    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular   // kept for call-site parity; Phosphor is one weight

    init(_ name: String, size: CGFloat = 17, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    private var asset: String { "jc_" + name.replacingOccurrences(of: ".", with: "_") }

    var body: some View {
        if UIImage(named: asset) != nil {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            // A name with no Phosphor mapping (usually built at runtime): keep Apple's.
            JcIcon(name)
                .font(.system(size: size * 0.92, weight: weight))
        }
    }
}

extension Label where Title == Text, Icon == JcIcon {
    /// `Label("Rename", jcIcon: "pencil")` — the Phosphor stand-in for `systemImage:`.
    init(_ title: String, jcIcon: String) {
        self.init { Text(title) } icon: { JcIcon(jcIcon, size: 16) }
    }
}

extension Button where Label == SwiftUI.Label<Text, JcIcon> {
    init(_ title: String, jcIcon: String, action: @escaping () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, jcIcon: jcIcon) }
    }

    init(_ title: String, jcIcon: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, jcIcon: jcIcon) }
    }
}

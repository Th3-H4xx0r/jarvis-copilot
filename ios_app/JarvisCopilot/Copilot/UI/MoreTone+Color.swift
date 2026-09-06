import SwiftUI

extension Color {
    /// Resolve a `MoreTone` palette slot to its `JcTheme` colour.
    ///
    /// `MoreTone` lives in the model layer (`Copilot/More/MoreSupport.swift`), which
    /// deliberately does not import SwiftUI — stores decide *which* slot a row uses,
    /// views decide what that slot looks like. This is the one place the two meet, so
    /// every More screen renders the same token the same way.
    init(tone: MoreTone) {
        switch tone {
        case .text: self = JcTheme.text
        case .muted: self = JcTheme.muted
        case .accent: self = JcTheme.accent
        case .accentAlt: self = JcTheme.accentAlt
        case .cyan: self = JcTheme.cyan
        case .blue: self = JcTheme.blue
        case .primaryBlue: self = JcTheme.primaryBlue
        case .success: self = JcTheme.success
        case .amber: self = JcTheme.amber
        case .slate: self = JcTheme.slate
        case .danger: self = JcTheme.danger
        }
    }
}

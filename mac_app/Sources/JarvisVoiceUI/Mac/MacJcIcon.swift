import SwiftUI

/// The Mac's `JcIcon`. The phone's (UI/Glass.swift) draws the Phosphor icon from
/// its asset catalog, which this dylib does not carry, and checks for it with
/// UIKit; here the shared voice views get Apple's symbol of the same name.
struct JcIcon: View {
    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular

    init(_ name: String, size: CGFloat = 17, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
    }
}

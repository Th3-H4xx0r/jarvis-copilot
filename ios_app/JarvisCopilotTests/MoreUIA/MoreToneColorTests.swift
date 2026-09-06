import SwiftUI
import XCTest
@testable import JarvisCopilot

/// `Color(tone:)` is the single bridge between the view-free More model layer
/// (`MoreTone`) and the theme. Every screen in the More tab reads a colour
/// through it, so the mapping has to be total and stable.
final class MoreToneColorTests: XCTestCase {

    /// The expected slot → token table, written out independently of the
    /// extension so a wrong retarget shows up as a failure rather than passing
    /// by construction.
    private let expected: [MoreTone: Color] = [
        .text: JcTheme.text,
        .muted: JcTheme.muted,
        .accent: JcTheme.accent,
        .accentAlt: JcTheme.accentAlt,
        .cyan: JcTheme.cyan,
        .blue: JcTheme.blue,
        .primaryBlue: JcTheme.primaryBlue,
        .success: JcTheme.success,
        .amber: JcTheme.amber,
        .slate: JcTheme.slate,
        .danger: JcTheme.danger,
    ]

    func testTheTableCoversEveryDeclaredTone() {
        XCTAssertEqual(Set(expected.keys), Set(MoreTone.allCases),
                       "a MoreTone case was added or removed without updating Color(tone:)")
    }

    func testEveryToneMapsToItsThemeToken() {
        for tone in MoreTone.allCases {
            guard let want = expected[tone] else {
                XCTFail("no expectation for \(tone)")
                continue
            }
            XCTAssertEqual(Color(tone: tone), want, "wrong colour for \(tone.rawValue)")
        }
    }

    /// Two slots resolving to the same colour would make status states
    /// indistinguishable, so the palette must stay injective.
    func testTonesResolveToDistinctColours() {
        let colours = MoreTone.allCases.map { Color(tone: $0) }
        XCTAssertEqual(Set(colours).count, MoreTone.allCases.count)
    }

    /// Guards the enum itself: the wire-facing raw values are what stores emit.
    func testToneRawValuesAreStable() {
        XCTAssertEqual(MoreTone.allCases.map(\.rawValue),
                       ["text", "muted", "accent", "accentAlt", "cyan", "blue",
                        "primaryBlue", "success", "amber", "slate", "danger"])
    }
}

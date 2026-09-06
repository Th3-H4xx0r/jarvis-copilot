import Foundation

/// The orb runs a continuous 60 fps blurred/additive draw. Because every page
/// lives forever in the tab shell, its ticker would otherwise keep repainting on
/// EVERY tab. It only needs to animate while its OWNING tab is the active tab
/// (the orb appears on both the Voice tab and the Chat empty-state). SwiftUI
/// already mutes `TimelineView` when the app is backgrounded. A nil `ownerTab`
/// means "always animate" (not nav-gated). Pure so it's unit-testable.
/// Port of `voice/orb_ticker_policy.dart`.
func orbTickerEnabled(activeTab: Int, ownerTab: Int?) -> Bool {
    ownerTab == nil || activeTab == ownerTab
}

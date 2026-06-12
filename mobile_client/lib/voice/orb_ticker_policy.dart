/// The orb runs a continuous 60fps blurred/additive CustomPainter. Because every
/// page lives forever in NavShell's IndexedStack, its ticker would otherwise keep
/// repainting on EVERY tab. It only needs to animate while its OWNING tab is the
/// active tab (the orb appears on both the Voice tab and the Chat empty-state).
/// Flutter already mutes tickers when the app is backgrounded. A null [ownerTab]
/// means "always animate" (not nav-gated). Pure so it's unit-testable.
bool orbTickerEnabled({required int activeTab, required int? ownerTab}) =>
    ownerTab == null || activeTab == ownerTab;

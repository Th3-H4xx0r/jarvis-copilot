import SwiftUI

extension View {
    /// Reports whether this page is really on screen: its tab is selected and the
    /// app is in the foreground. Every tab stays mounted in the shell and the
    /// background keepalive keeps the process running, so `onAppear` /
    /// `onDisappear` alone never see a tab switch or a trip to the background —
    /// work started there would keep running all night.
    func onTabVisibilityChange(_ tab: AppTab, perform action: @escaping (Bool) -> Void) -> some View {
        modifier(TabVisibilityModifier(tab: tab, action: action))
    }
}

private struct TabVisibilityModifier: ViewModifier {
    let tab: AppTab
    let action: (Bool) -> Void
    /// Optional so a page hosted without the shell (previews, tests) still works.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase

    private var visible: Bool {
        scenePhase == .active && (router.map { $0.selectedTab == tab } ?? true)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: visible, initial: true) { _, isVisible in action(isVisible) }
            .onDisappear { action(false) }
    }
}

extension View {
    /// Reports whether this pushed More screen is really on screen: shown in the
    /// stack (not covered by a pushed screen), the More tab selected, the app in
    /// the foreground. `onTabVisibilityChange` alone misses a return from a
    /// pushed screen: the page stays alive underneath it, so its initial-only
    /// `onChange` never fires again.
    func moreScreenVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(MoreScreenVisibilityModifier(action: action))
    }
}

private struct MoreScreenVisibilityModifier: ViewModifier {
    let action: (Bool) -> Void
    /// Optional so a page hosted without the shell (previews, tests) still works.
    @Environment(AppRouter.self) private var router: AppRouter?
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

    private var foreground: Bool {
        scenePhase == .active && (router.map { $0.selectedTab == .more } ?? true)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen = true
                action(foreground)
            }
            .onDisappear {
                onScreen = false
                action(false)
            }
            .onChange(of: foreground) { _, now in
                if onScreen { action(now) }
            }
    }
}

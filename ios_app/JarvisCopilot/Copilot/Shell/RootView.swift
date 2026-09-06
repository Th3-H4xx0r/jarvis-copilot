import SwiftUI

/// The boot gate, ported from `main.dart`'s `_Boot`: an unpaired device gets the
/// pair page, a paired one gets the shell.
///
/// `BridgeClient` is the source of truth (its session cookie lives in the
/// Keychain and therefore survives a reinstall). It is still an
/// `ObservableObject`, so observing it here is what re-renders the gate the
/// moment a pair or unpair lands.
struct RootView: View {
    // `@ObservedObject`, not `@StateObject`: the bridge is a singleton this view
    // does not own. `@StateObject` would have SwiftUI take ownership of an
    // object whose lifetime is the process's, and its autoclosure initialiser
    // makes the "created once" contract a lie the first time the gate is rebuilt.
    @ObservedObject private var bridge = BridgeClient.shared
    @State private var router = AppRouter.shared

    var body: some View {
        Group {
            if bridge.isPaired {
                NavShell()
            } else {
                NavigationStack { PairPage() }
            }
        }
        .environment(router)
        // Dark-only: the embedded webui tabs render dark, so a light/dark flip
        // would flicker between native and web screens.
        .preferredColorScheme(.dark)
        .tint(JcTheme.accent)
    }
}

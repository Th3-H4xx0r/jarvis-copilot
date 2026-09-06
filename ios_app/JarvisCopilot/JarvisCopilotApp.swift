import SwiftUI
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Opportunistic background wake, used to drain commands Jarvis queued while the app
/// was suspended. iOS decides when (and whether) to run these, so it complements the
/// CoreBluetooth wake path rather than replacing it.
let backgroundRefreshID = "com.jarviscopilot.jarviscopilotMobileAndIOS.refresh"

@main
struct JarvisCopilotApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @Environment(\.scenePhase) private var scenePhase

    /// Everything `main.dart` did before `runApp`. Here rather than in a `.task`
    /// because the notification delegate has to exist before iOS delivers a tap
    /// that launched the app, and the skill registry has to be populated before
    /// the bridge socket advertises it.
    init() {
        MainActor.assumeIsolated { AppServices.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            // The Copilot shell: the pair screen until this device is paired,
            // then the 6-tab nav (Devices is still `ScanView`).
            RootView()
                // Shortcut x-callback results and `jarviscopilot://` deep links
                // (voice, chat?session=, coding?session=).
                .onOpenURL { AppServices.shared.open(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    AppServices.shared.setForeground(phase == .active)
                    #if os(iOS)
                    if phase == .background { scheduleBackgroundRefresh() }
                    #endif
                }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(backgroundRefreshID)) {
            await BridgeClient.shared.drainQueue(foreground: false)
            await scheduleBackgroundRefresh()
        }
        #endif
    }
}

#if os(iOS)
@MainActor
func scheduleBackgroundRefresh() {
    guard BridgeClient.shared.enabled else { return }
    let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}
#else
@MainActor func scheduleBackgroundRefresh() {}
#endif

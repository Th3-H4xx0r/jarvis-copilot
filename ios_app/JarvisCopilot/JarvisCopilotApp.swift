import SwiftUI
import BackgroundTasks

/// Opportunistic background wake, used to drain commands Jarvis queued while the app
/// was suspended. iOS decides when (and whether) to run these, so it complements the
/// CoreBluetooth wake path rather than replacing it.
let backgroundRefreshID = "com.jarviscopilot.jarviscopilotMobileAndIOS.refresh"

@main
struct JarvisCopilotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    /// Everything `main.dart` did before `runApp`. Here rather than in a `.task`
    /// because the notification delegate has to exist before iOS delivers a tap
    /// that launched the app, and the skill registry has to be populated before
    /// the bridge socket advertises it.
    init() {
        // System alerts and action sheets tint from the window, not SwiftUI.
        UIWindow.appearance().tintColor = UIColor(JcTheme.accent)
        MainActor.assumeIsolated {
            AppServices.shared.start()
            // Before anything can show a stale one: a "recording" Live Activity
            // that outlives the recording tells the user their room is being
            // listened to when it is not.
            LiveCaptureBeacon.shared.observeAppLifecycle()
            LiveCaptureBeacon.shared.reapOrphans()
        }
    }

    var body: some Scene {
        WindowGroup {
            // The Copilot shell: the pair screen until this device is paired,
            // then the 6-tab nav (Devices is still `ScanView`).
            RootView()
                // Shortcut x-callback results and `jarviscopilot://` deep links
                // (voice, chat?session=, coding?session=).
                .onOpenURL { AppServices.shared.open(url: $0) }
                // WCSession has to be live from LAUNCH, not from the first
                // foreground: iOS background-launches this app to deliver the
                // watch's message, and with no delegate set by then the watch
                // just reports that it cannot reach the phone.
                .task { WatchBridge.shared.activate() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    AppServices.shared.setForeground(phase == .active)
                    if phase == .background { scheduleBackgroundRefresh() }
                    // `Activity.request` throws while backgrounded, which is
                    // exactly where a voice-driven "start the stopwatch" runs;
                    // open the island we owe as soon as we come forward.
                    if phase == .active { StopwatchService.shared.resyncActivity() }
                    // The backstop for the recording activity. `willTerminate`
                    // is not guaranteed and an activity outlives the process,
                    // so a fresh foreground — which by definition is not
                    // capturing yet — is where a ghost is caught.
                    if phase == .active { LiveCaptureBeacon.shared.reapOrphans() }
                }
        }
        .backgroundTask(.appRefresh(backgroundRefreshID)) {
            await BridgeClient.shared.drainQueue(foreground: false)
            await scheduleBackgroundRefresh()
        }
    }
}

@MainActor
func scheduleBackgroundRefresh() {
    guard BridgeClient.shared.enabled else { return }
    let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}

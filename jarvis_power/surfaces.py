"""Every place on a device that belongs to a Power integration and hides while it's off.

An integration lists its surface ids in ``surfaces``; each id must be here, with
where it lives, so the next person adding a device check knows the place exists and
what it's called. Devices gate by integration id (``PowerState.isOn("dashcam")``,
``JCPower.isOn("kanban")``); these ids are the documented map of where those checks sit.
Paths are relative to ios_app/JarvisCopilot, webui/static and mac_app.
"""

CATALOG: dict[str, str] = {
    # ── iPhone ──────────────────────────────────────────────────────────────
    "ios.more.kanban": "More grid tile → KanbanPage (Copilot/More/MorePage.swift, MoreDestination.swift)",
    "ios.more.security": "More grid tile → Security Advisor (Copilot/More/MorePage.swift)",
    "ios.more.island": "More grid tile → Dynamic Island designs (Copilot/More/MorePage.swift)",
    "ios.more.photon": "More grid tile → PhotonSetupPage (Copilot/More/MorePage.swift)",
    "ios.deeplink.security": "jarviscopilot://security (Copilot/Services/AppDeepLink.swift)",
    "ios.deeplink.island": "jarviscopilot://island (Copilot/Services/AppDeepLink.swift)",
    "ios.push.security_alert": "SECURITY_ALERT push category (Copilot/Services/PushHandler.swift)",
    "ios.push.imessage_facts": "IMESSAGE_FACTS push category (Copilot/Services/PushHandler.swift)",
    "ios.integrations.imessage": "iMessage memory screen (Copilot/More/Integrations/IMessageMemory)",
    "ios.chat.imessage_facts": "Fact cards on the Chat home (Copilot/Chat/ChatPage.swift)",
    "ios.tab.health": "Health tab (Copilot/Shell/AppRouter.swift, NavShell.swift)",
    "ios.widget.health": "Health widget (JarvisWidget)",
    "ios.liveactivity.workout": "Ring workout Live Activity (JarvisWidget/JarvisLiveActivity.swift)",
    "ios.devices.car": "Car entry card on Devices → CarPage (ScanView.swift)",
    "ios.bridge.car": "CarDevice bridge skills car_* (Car/CarDevice.swift, AppServices)",
    "ios.carplay.car": "CarPlay car tab (CarPlay/CarPlayCoordinator.swift)",
    "ios.devices.door": "Door alarm entry card on Devices (ScanView.swift)",
    "ios.bridge.door": "DoorAlarmDevice skills door_alarm_ring / door_show_approvals (DoorAlarm/DoorAlarmDevice.swift)",
    "ios.alert.door": "Full-screen door alarm alert (JarvisCopilotApp.swift)",
    "ios.controls.door": "Control button live door states (Copilot/Shared/ControlButtons.swift)",
    "ios.devices.dashcam": "Dashcam card on Devices or under the car (Dashcam/DashcamLinkable.swift)",
    "ios.bg.dashcam": "DashcamSync: Wi-Fi watcher, motion, uploads (Dashcam/DashcamSync.swift)",
    "ios.carplay.dashcam": "CarPlay dashcam screens (CarPlay/Screens/CarPlayDashcamScreens.swift)",
    "ios.liveactivity.dashcam": "Dashcam sync Live Activity (JarvisWidget/DashcamSyncActivity.swift)",
    "ios.settings.vault": "Settings → Privacy → Secure vault (Copilot/Settings/SettingsPage.swift)",
    "ios.share.vault": "Jarvis Vault share extension (JarvisVaultShare)",
    "ios.settings.widgets": "Settings → Widgets (Copilot/Settings/SettingsPage.swift)",
    "ios.bg.widgets": "WidgetDataHub + WidgetSync (Widgets/)",
    "ios.widget.designs": "Jarvis design widgets (JarvisWidget/JarvisDesignWidget.swift)",
    "ios.liveactivity.island_designs": "Custom Dynamic Island designs (Copilot/Services/LiveActivityCoordinator.swift)",
    "ios.codemaster.agent_activity": "Agent activity section in Code Master settings (Copilot/Agents/Views/CodeMasterSettingsPage.swift)",
    # ── web ─────────────────────────────────────────────────────────────────
    "web.rail.kanban": "Kanban rail button + header tab (index.html data-power)",
    "web.rail.security": "Security rail button + header tab (index.html data-power)",
    "web.settings.photon": "Photon card in Settings → Integrations (panels.js)",
    "web.integrations.imessage": "iMessage memory card in the Integrations sidebar (integrations.js)",
    # ── Mac ─────────────────────────────────────────────────────────────────
    "mac.settings.photon": "Photon card in the Mac settings window (embedded web settings)",
    "mac.tray.imessage": "iMessage uploader in the Mac tray (desktop_client/jc_client/imessage_memory.py)",
}

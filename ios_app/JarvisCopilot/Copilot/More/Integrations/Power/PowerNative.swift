import SwiftUI

/// Native views a Power integration can ship instead of its JSON card, page or settings
/// form (the manifest's `native` says which ones exist). Empty until one needs it:
/// add a `case` returning the view, and add the piece to `native` on the server.
enum PowerNative {
    static func card(_ row: PowerRow) -> AnyView? {
        // Game Streaming ships a native card; the iOS client owns that decision
        // for this built-in, so it renders whether or not the server lists it in
        // the manifest's `native`. Others gate on that list.
        if row.id == "game-streaming" { return AnyView(GameStreamingCard()) }
        guard row.nativePieces["ios"]?.contains("card") == true else { return nil }
        switch row.id {
        default: return nil
        }
    }

    static func page(_ row: PowerRow) -> AnyView? {
        // Game Streaming ships a native page (see `card` above for why it renders
        // without the server's `native` flag).
        if row.id == "game-streaming" { return AnyView(GameStreamingPage()) }
        guard row.nativePieces["ios"]?.contains("page") == true else { return nil }
        switch row.id {
        default: return nil
        }
    }

    static func settings(_ row: PowerRow) -> AnyView? {
        guard row.nativePieces["ios"]?.contains("settings") == true else { return nil }
        switch row.id {
        default: return nil
        }
    }
}

/// The existing screen a Power link opens on the iPhone (`Link("ios", target, …)`).
enum PowerLinkDestination {
    @MainActor @ViewBuilder
    static func view(for target: String) -> some View {
        switch target {
        case "car_page": CarPage()
        case "door_page": DoorAlarmPage()
        case "dashcam_page":
            if DashcamSetupStore.load() == nil { DashcamSetupView() } else { DashcamPage() }
        case "vault": VaultRootView()
        case "widgets": WidgetCreatorPage()
        case "kanban": KanbanPage()
        case "security": SecurityPage()
        case "island_designs": IslandDesignsPage()
        case "photon": PhotonSetupPage()
        case "imessage": IMessageMemoryView(store: IMessageMemoryStore())
        case "holo_drop", "holo_drop_page": HoloDropPage()
        default: Text("This opens elsewhere on your iPhone.").foregroundStyle(JcTheme.muted)
        }
    }

    /// Targets that switch tabs instead of pushing a screen.
    static func isTab(_ target: String) -> Bool { target == "health_tab" }

    /// Targets that do something at once instead of pushing a screen (Holo Drop's Orbit).
    @MainActor
    static func action(_ target: String) -> (() -> Void)? {
        target == "holo_drop" ? { HoloLauncher.shared.openQuick() } : nil
    }
}

import SwiftUI

/// Native views a Power integration can ship instead of its JSON card, page or settings
/// form (the manifest's `native` says which ones exist). Empty until one needs it:
/// add a `case` returning the view, and add the piece to `native` on the server.
enum PowerNative {
    static func card(_ row: PowerRow) -> AnyView? {
        guard row.nativePieces["ios"]?.contains("card") == true else { return nil }
        switch row.id {
        default: return nil
        }
    }

    static func page(_ row: PowerRow) -> AnyView? {
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
        default: Text("This opens elsewhere on your iPhone.").foregroundStyle(JcTheme.muted)
        }
    }

    /// Targets that switch tabs instead of pushing a screen.
    static func isTab(_ target: String) -> Bool { target == "health_tab" }
}

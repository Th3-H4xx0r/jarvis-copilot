import Foundation

/// What Jarvis can ask the phone to do about widgets.
enum WidgetSkills {
    /// Called by the `widgets` skill after it saves or deletes a design, so the new design is on
    /// the Home Screen at once instead of at the next launch.
    static func refresh() -> AnySkill {
        AnySkill(
            name: "widgets_refresh",
            description: "Pull the widget designs from the Jarvis server into this phone's widgets now "
                + "(after creating, changing or deleting one)."
        ) { _ in
            await WidgetSync.shared.sync()
            return ["ok": true, "designs": WidgetDesignCache.infos().map(\.name)]
        }
    }
}

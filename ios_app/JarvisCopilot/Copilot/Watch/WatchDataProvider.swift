import Foundation

/// What the watch asks the phone for, beyond running a turn.
///
/// The watch has no API client and no Bluetooth radios of its own, so the phone
/// answers on its behalf — from the SAME `WearablesHub` managers and the SAME
/// `SessionsAPI` the phone's own screens use. Nothing is re-implemented here;
/// these are snapshots, shaped for a small screen.
@MainActor
enum WatchDataProvider {

    // MARK: - Chats

    /// Recent conversations for the watch's chat picker, plus which one voice
    /// is pointed at, so the two surfaces agree.
    static func sessions(api: JarvisAPI, limit: Int = 12) async -> [String: Any] {
        do {
            let all = try await SessionsAPI(api: api).list()
            let rows = all.prefix(limit).map { session -> [String: Any] in
                ["id": session.id,
                 "title": session.title.isEmpty ? "Untitled" : session.title,
                 "messages": session.messageCount ?? 0]
            }
            return ["ok": true, "sessions": Array(rows),
                    "selected": VoiceSessionSelection.shared.target.sessionID ?? ""]
        } catch {
            return ["ok": false, "error": apiErrorMessage(error)]
        }
    }

    /// Point voice — on BOTH surfaces — at a chat. Passing an empty id means
    /// "the default Voice chat".
    static func selectSession(_ id: String) -> [String: Any] {
        if id.isEmpty {
            VoiceSessionSelection.shared.select(.defaultVoice)
        } else {
            VoiceSessionSelection.shared.select(.session(id: id, title: ""))
        }
        VoiceSessionResolver.shared.invalidate()
        return ["ok": true]
    }

    /// Start a fresh conversation and point voice at it.
    static func newSession(api: JarvisAPI) async -> [String: Any] {
        do {
            let id = try await SessionsAPI(api: api).create(title: "Voice")
            VoiceSessionSelection.shared.select(.session(id: id, title: "Voice"))
            VoiceSessionResolver.shared.invalidate()
            return ["ok": true, "id": id]
        } catch {
            return ["ok": false, "error": apiErrorMessage(error)]
        }
    }

    // MARK: - Wearables

    /// One row per wearable, in the SAME shape for each so the watch can render
    /// them with a single view: a name, a connection line, and up to three
    /// readings.
    static func wearables() -> [String: Any] {
        let hub = WearablesHub.shared
        var rows: [[String: Any]] = []

        var bottle: [String: Any] = [
            "id": "bottle", "name": hub.bottle.connected?.name ?? "Water bottle",
            "symbol": "waterbottle", "state": hub.bottle.state.text,
            "connected": hub.bottle.state == .ready,
        ]
        if let status = hub.bottle.status {
            bottle["readings"] = [
                ["label": "Battery", "value": "\(status.batteryPercent)%"],
                ["label": "Water", "value": "\(status.temperatureC)°C"],
                ["label": "UV", "value": status.isSterilising
                    ? "Cleaning \(max(0, 100 - status.steriliseProgress))%" : "Idle"],
            ]
        }
        rows.append(bottle)

        var scale: [String: Any] = [
            "id": "scale", "name": hub.scale.connected?.name ?? "Scale",
            "symbol": "scalemass", "state": hub.scale.state.text,
            "connected": hub.scale.state == .ready,
        ]
        if let observation = hub.scale.latestObservation {
            scale["readings"] = [
                ["label": "Weight", "value": String(format: "%.1f kg", observation.weightKg)],
                ["label": "Reading", "value": observation.isStable ? "Stable" : "Settling"],
            ]
        }
        rows.append(scale)

        var board: [String: Any] = [
            "id": "esp32", "name": hub.esp32.connected?.name ?? "ESP32 board",
            "symbol": "cpu", "state": hub.esp32.state.text,
            "connected": hub.esp32.state == .ready,
        ]
        if let info = hub.esp32.info {
            board["readings"] = [["label": "Firmware", "value": info.firmwareString]]
        }
        rows.append(board)

        return ["ok": true, "wearables": rows]
    }
}

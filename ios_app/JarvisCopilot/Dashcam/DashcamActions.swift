import Foundation

// The dashcam's buttons and readouts as plain functions, so the phone's views and
// the CarPlay screens run exactly the same code. Every camera action goes through
// the same `dashcam_*` skills the agent uses (`DashcamDevice.invoke`).

/// The camera's sound recording, with the camera's own codes for on and off.
struct DashcamMic: Equatable {
    var on: Bool
    var onCode: String
    var offCode: String

    /// The `mic` row of the camera's settings list, or nil when the camera has none.
    static func from(_ items: [DashcamSettingItem]) -> DashcamMic? {
        guard let row = items.first(where: { $0.name == "mic" }) else { return nil }
        var mic = DashcamMic(on: false, onCode: "1", offCode: "0")
        for option in row.options {
            switch DashcamControls.isOn(option.label) ?? DashcamControls.isOn(option.code) {
            case true?: mic.onCode = option.code
            case false?: mic.offCode = option.code
            case nil: break
            }
        }
        // A state the camera doesn't report as on or off hides the control (as the card always did).
        guard let on = DashcamControls.isOn(row.currentLabel) ?? DashcamControls.isOn(row.value) else { return nil }
        mic.on = on
        return mic
    }
}

/// The Controls card: record, photo, lock the clip, mic. Each returns the line to show.
@MainActor
enum DashcamControls {
    static func toggleRecording(sync: DashcamSync? = nil) async -> String {
        let sync = sync ?? .shared
        await sync.refreshStatus()                 // act on what the camera is doing now, not the last read
        let on = sync.recording == false
        do {
            let out = try await DashcamDevice.shared.invoke("dashcam_set_recording", args: ["enabled": on])
            let now = out["recording"] as? Bool ?? on
            return now ? "Recording." : "Recording stopped — it stays off until you start it again."
        } catch {
            return error.localizedDescription
        }
    }

    static func photo() async -> String {
        do {
            _ = try await DashcamDevice.shared.invoke("dashcam_snapshot", args: [:])
            return "Photo taken. It comes down with the next sync."
        } catch {
            return error.localizedDescription
        }
    }

    static func lock() async -> String {
        do {
            _ = try await DashcamDevice.shared.invoke("dashcam_lock_clip", args: [:])
            return "This clip is locked as an event, so the camera won't record over it. It's pulled first."
        } catch {
            return error.localizedDescription
        }
    }

    /// The mic's state, read from the camera (nil off its Wi‑Fi or when it has no mic setting).
    static func mic() async -> DashcamMic? {
        guard let items = try? await DashcamCameraSettings.load() else { return nil }
        return DashcamMic.from(items)
    }

    /// `ok` is false when the camera refused; `note` is the line to show either way.
    static func setMic(_ on: Bool, _ mic: DashcamMic) async -> (ok: Bool, note: String) {
        do {
            try await DashcamCameraSettings.set("mic", on ? mic.onCode : mic.offCode)
            return (true, on ? "The camera records sound again." : "The camera records without sound.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    nonisolated static func isOn(_ value: Any?) -> Bool? {
        switch value {
        case let s as String:
            let s = s.lowercased()
            return ["1", "on", "true"].contains(s) ? true : ["0", "off", "false"].contains(s) ? false : nil
        case let n as NSNumber: return n.intValue != 0
        default: return nil
        }
    }
}

/// The camera's own settings list (only while the phone is on its Wi‑Fi).
@MainActor
enum DashcamCameraSettings {
    static func load() async throws -> [DashcamSettingItem] {
        let result = try await DashcamDevice.shared.invoke("dashcam_get_settings", args: [:])
        return (result["settings"] as? [[String: Any]] ?? []).compactMap { row in
            guard let key = row["key"] as? String else { return nil }
            let options = (row["options"] as? [[String: Any]] ?? []).compactMap { o -> DashcamSettingItem.Option? in
                guard let c = o["code"] as? String, let l = o["label"] as? String else { return nil }
                return .init(code: c, label: l)
            }
            return DashcamSettingItem(name: key, value: row["value"] as? String, options: options, range: row["range"] as? String)
        }
    }

    static func set(_ name: String, _ code: String) async throws {
        _ = try await DashcamDevice.shared.invoke("dashcam_set_setting", args: ["key": name, "value": code])
    }

    nonisolated static func title(_ key: String) -> String {
        let known = ["rec_resolution": "Resolution", "rec_split_duration": "Clip length", "gsr_sensitivity": "G‑sensor",
                     "park_gsr_sensitivity": "Parking G‑sensor", "parking_monitor": "Parking monitor", "parking_mode": "Parking mode",
                     "mic": "Microphone", "speed_unit": "Speed unit", "osd": "Date & speed stamp", "wdr": "WDR", "ev": "Exposure",
                     "speaker": "Volume", "voice_control": "Voice control", "boot_sound": "Start-up sound", "key_tone": "Key tone",
                     "light_fre": "Light frequency", "screen_standby": "Screen saver", "auto_poweroff": "Auto power off",
                     "low_power_protect": "Low-voltage cut-off", "timelapse_rate": "Time-lapse rate", "park_record_time": "Parking recording",
                     "encodec": "Video codec", "language": "Language", "rear_mirror": "Mirror rear camera", "video_flip": "Flip video",
                     "video_mirror": "Mirror video", "low_fps_record": "Time-lapse parking", "adas": "Driver assist alerts",
                     "rear_first": "Preview lens", "power_supply": "Power supply", "front_rotate": "Rotate front camera",
                     "gps": "GPS", "gps_watermark": "GPS stamp", "time_watermark": "Date stamp", "speed_watermark": "Speed stamp"]
        return known[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// What a clip's Pull / Retry / Delete buttons do.
@MainActor
enum DashcamClipActions {
    typealias Place = DashcamLibraryModel.Place

    /// Deletes the clip from the chosen places. `done` names what went, `failed` what didn't (with why).
    /// A locked (tagged) clip is never deleted from anywhere: nothing happens and `failed` says why. The phone's copy
    /// goes only once the server says the clip isn't locked — the cloud delete going through, or the clip read again
    /// now — and never when the cloud delete asked for alongside it failed.
    static func delete(_ clip: DashcamServerClip, _ places: Set<Place>,
                       sync: DashcamSync? = nil, api: DashcamAPI? = nil) async -> (done: [String], failed: [String]) {
        let sync = sync ?? .shared
        let api = api ?? DashcamAPI()
        // What this phone knows first (the clip as listed may be older than a tag): its record of tagged clips and
        // what the server said this run. Before the tombstone below too: a locked clip must stay on the phone.
        guard !DashcamLock.isLocked(clip, defaults: sync.defaults), !sync.lockedIDs().contains(clip.id) else {
            return ([], [DashcamLock.refusal])
        }
        var done: [String] = [], failed: [String] = []
        // Remembered before anything else: a download of this clip still running lands after the delete,
        // and must not bring it back (two clips came back that way and retried their upload all week).
        if places.contains(.phone) { DashcamTombstones.add(clip.id, defaults: sync.defaults) }
        func refuse() -> (done: [String], failed: [String]) {
            DashcamTombstones.remove(clip.id, defaults: sync.defaults)
            return ([], [DashcamLock.refusal])
        }
        var cloudWent = false
        if places.contains(.cloud) {
            do { try await api.deleteFromCloud(clipID: clip.id); done.append("cloud"); cloudWent = true }
            catch where DashcamAPI.isLockedRefusal(error) {
                // Tagged since this phone last heard (423): it is locked, so nothing else goes either.
                DashcamTagged.learn(ids: [clip.id], defaults: sync.defaults)
                return refuse()
            }
            catch { failed.append("cloud: \(error.localizedDescription)") }
        }
        if places.contains(.phone) {
            if places.contains(.cloud) && !cloudWent {
                DashcamTombstones.remove(clip.id, defaults: sync.defaults)
                failed.append("phone: kept, since the cloud delete didn't go through")
            } else {
                // No cloud delete to have asked the server: the clip is read again, and a locked (or unreadable) one
                // keeps its phone copy.
                if !cloudWent {
                    do {
                        let fresh = try await api.clip(clip.id).clip
                        sync.noteServerClips([fresh])
                        if DashcamLock.isLocked(fresh, tagged: []) {
                            DashcamTagged.learn([fresh], defaults: sync.defaults)
                            return refuse()
                        }
                    } catch where DashcamAPI.isClipGone(error) {
                        // Forgotten everywhere already: nothing on the server can lock it.
                    } catch {
                        DashcamTombstones.remove(clip.id, defaults: sync.defaults)
                        return (done, failed + ["phone: couldn't check with the Jarvis server that it isn't locked (\(error.localizedDescription)). Try again."])
                    }
                }
                let setup = DashcamSetupStore.load()
                let camera = clip.cameraID.isEmpty ? (setup?.cameraID ?? "") : clip.cameraID
                let f = DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start, durationS: clip.durationS, size: clip.size)
                try? FileManager.default.removeItem(at: sync.storage.localURL(camera: camera, file: f))
                await sync.uploader.remove(clipID: clip.id)
                try? await api.setPhone(clipID: clip.id, state: "deleted", error: nil)
                done.append("phone")
            }
        }
        let everywhere = places == [.phone, .cloud, .camera]
        var waiting = false
        if places.contains(.camera), clip.onCamera {
            // Now when on the camera's Wi‑Fi, otherwise it waits in the server's backlog for the next connection —
            // never lost, and marked "Pending deletion" in the library until then. The server may refuse it as locked:
            // that is said, never shown as pending.
            switch await sync.deleteFromCamera(clip.path, clipID: clip.id, forget: everywhere && failed.isEmpty) {
            case .deleted: done.append("dashcam")
            case .pending:
                waiting = true
                done.append("dashcam (pending — deletes when next connected)")
            case .locked: failed.append("dashcam: \(DashcamLock.refusal)")
            }
        }
        // Gone from the library too — but a clip still waiting on the card stays (marked) until the camera has
        // deleted it; the server forgets it then.
        if everywhere, failed.isEmpty, !waiting {
            try? await api.forgetClip(clip.id)
        }
        return (done, failed)
    }

    /// Queue the clip off the camera; returns the line to show.
    static func pull(_ clip: DashcamServerClip, sync: DashcamSync? = nil, onCamera: Bool? = nil) -> String {
        (sync ?? .shared).pull(clip.path)
        return onCamera ?? DashcamWiFi.shared.onCamera ? "Pulling \(clip.name)…" : "\(clip.name) will be pulled next time the phone is on the camera's Wi‑Fi."
    }

    static func retryUpload(_ clip: DashcamServerClip, sync: DashcamSync? = nil) async {
        try? await DashcamAPI().retry(clipID: clip.id)
        (sync ?? .shared).kickUploads()
    }
}

/// The line under the dashcam's status: last sync and what is waiting.
enum DashcamStatusText {
    static func subtitle(lastSync: Date?, pendingUploads: Int, queuedDownloads: Int) -> String {
        var parts: [String] = []
        if let lastSync { parts.append("Synced \(lastSync.formatted(.relative(presentation: .named)))") }
        if pendingUploads > 0 { parts.append("\(pendingUploads) to upload") }
        if queuedDownloads > 0 { parts.append("\(queuedDownloads) to download") }
        return parts.isEmpty ? "Joins on its own when the camera is on" : parts.joined(separator: " · ")
    }
}

/// Drives: the last-7-days summary, grouping by day, and each drive's row text.
enum DashcamDriveStats {
    struct Week: Equatable {
        var count: Int
        var distanceM: Double
        var topMps: Double?
    }

    static func week(_ drives: [DashcamDrive], now: Date) -> Week {
        let week = drives.filter { $0.start > now.addingTimeInterval(-7 * 86400) }
        return Week(count: week.count, distanceM: week.reduce(0) { $0 + $1.distanceM }, topMps: week.map(\.maxMps).max())
    }

    static func byDay(_ drives: [DashcamDrive], calendar: Calendar, now: Date) -> [(String, [DashcamDrive])] {
        let groups = Dictionary(grouping: drives) { calendar.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) { title = "Today" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            return (title, groups[day, default: []].sorted { $0.start > $1.start })
        }
    }

    static func title(_ d: DashcamDrive) -> String {
        "\(d.start.formatted(date: .omitted, time: .shortened)) – \(d.end.formatted(date: .omitted, time: .shortened))"
    }

    static func detail(_ d: DashcamDrive) -> String {
        "\(DashcamSpeed.miles(d.distanceM)) · \(DashcamSpeed.duration(d.durationS)) · top \(DashcamSpeed.text(d.maxMps)) mph"
    }
}

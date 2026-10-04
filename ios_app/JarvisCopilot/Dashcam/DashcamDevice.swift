import Foundation

/// The dashcam as a Jarvis device: its `dashcam_*` skills reach the agent through the device
/// bridge, ring gestures and Control Center buttons (via `DeviceRegistry`). Commands that talk to
/// the camera need the phone on its Wi‑Fi; status and fetch requests work any time.
@MainActor
final class DashcamDevice: WearableDevice {
    static let shared = DashcamDevice()
    static let model = "Dashcam"
    static let identityKey = "dashcam"

    private var registeredID: String?
    var sync: DashcamSync = .shared
    var wifi: () -> Bool = { DashcamWiFi.shared.onCamera }
    var setup: () -> DashcamSetup? = { DashcamSetupStore.load() }

    var deviceID: String { setup()?.deviceID ?? "dashcam" }
    var isConnected: Bool { wifi() }
    /// The dashcam lives in the car: it's on Jarvis's CarPlay Wearables tab.
    var carEnabled: Bool { true }

    /// Adds or removes the dashcam from Jarvis to match setup + "Share with Jarvis".
    func refreshMembership() {
        if let old = registeredID, old != deviceID { DeviceRegistry.shared.remove(deviceID: old) }
        guard let setup = setup() else {
            if let old = registeredID { DeviceRegistry.shared.remove(deviceID: old) }
            registeredID = nil
            return
        }
        registeredID = deviceID
        DeviceRegistry.shared.syncMembership(of: self, identity: Self.identityKey, model: setup.displayName)
    }

    // MARK: Skills

    private static let noArgs = DeviceCapability.schema()

    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(name: "dashcam_get_status", description: """
                The dashcam's state: whether the phone is on its Wi‑Fi, recording, SD card space, \
                the last sync, clips waiting to download or upload, and the newest clips on the card.
                """, inputSchema: Self.noArgs),
            DeviceCapability(name: "dashcam_sync", description: """
                Sync with the dashcam now: set its clock, read GPS and thumbnails for every clip, pull \
                events, photos and any footage the rules allow, and queue uploads. Needs the phone on \
                the dashcam's Wi‑Fi (it joins on its own when the camera is on).
                """, inputSchema: DeviceCapability.schema([
                    "resync": ["type": "boolean", "description": "Forget what was listed last time and re-read everything."],
                ])),
            DeviceCapability(name: "dashcam_lock_clip", description: """
                "Save this moment": lock the clip being recorded so the camera never loops over it; \
                it is pulled to the phone and uploaded like any event.
                """, inputSchema: Self.noArgs),
            DeviceCapability(name: "dashcam_snapshot", description: """
                Take a photo with the dashcam. The photo lands in the dashcam library and is uploaded.
                """, inputSchema: DeviceCapability.schema([
                    "lens": ["type": "string", "enum": ["front", "rear"], "description": "Which camera. Defaults to front."],
                ])),
            DeviceCapability(name: "dashcam_set_recording", description: "Start or stop the dashcam recording.",
                             inputSchema: DeviceCapability.schema([
                                "enabled": ["type": "boolean", "description": "true to record, false to stop."],
                             ], required: ["enabled"])),
            DeviceCapability(name: "dashcam_get_settings", description: """
                Every dashcam setting with its current value and allowed values (resolution, loop length, \
                G-sensor, parking mode, microphone, speed stamp unit, …).
                """, inputSchema: Self.noArgs),
            DeviceCapability(name: "dashcam_set_setting", description: """
                Change one dashcam setting. Use a key and one of its values from dashcam_get_settings \
                (the code or the label).
                """, inputSchema: DeviceCapability.schema([
                    "key": ["type": "string", "description": "Setting name, e.g. rec_split_duration."],
                    "value": ["type": "string", "description": "Allowed value code or label."],
                ], required: ["key", "value"])),
            DeviceCapability(name: "dashcam_sd_info", description: "The dashcam's SD card: present, total and free space.",
                             inputSchema: Self.noArgs),
            DeviceCapability(name: "dashcam_format_sd", description: """
                Erase the dashcam's SD card. Destroys every clip on the card, including locked events \
                that have not been uploaded. Requires confirm=true.
                """, inputSchema: DeviceCapability.schema([
                    "confirm": ["type": "boolean", "description": "Must be true."],
                ], required: ["confirm"])),
            DeviceCapability(name: "dashcam_delete_file", description: """
                Delete one file from the dashcam's card (path from the library). Requires confirm=true.
                """, inputSchema: DeviceCapability.schema([
                    "path": ["type": "string", "description": "The file's path on the camera."],
                    "confirm": ["type": "boolean", "description": "Must be true."],
                ], required: ["path", "confirm"])),
            DeviceCapability(name: "dashcam_set_wifi", description: """
                Change the dashcam's Wi‑Fi name and/or password. The phone saves the new network so it \
                keeps joining automatically.
                """, inputSchema: DeviceCapability.schema([
                    "ssid": ["type": "string", "description": "New Wi‑Fi name."],
                    "password": ["type": "string", "description": "New Wi‑Fi password (8+ characters)."],
                ])),
            DeviceCapability(name: "dashcam_fetch_range", description: """
                Pull and upload every clip recorded between two times, whatever the rules say \
                ("get the clip from 3:40pm"). Fetched now if the phone is on the dashcam's Wi‑Fi, \
                otherwise next time it is.
                """, inputSchema: DeviceCapability.schema([
                    "from": ["type": "string", "description": "Start, ISO-8601 (e.g. 2026-10-01T20:38:00Z)."],
                    "to": ["type": "string", "description": "End, ISO-8601."],
                ], required: ["from", "to"])),
        ]
    }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "set_up": setup() != nil,
            "on_camera_wifi": wifi(),
            "phase": sync.phase.label,
            "downloads_queued": sync.queuedDownloads,
            "uploads_pending": sync.pendingUploads,
            "clips_on_card": sync.cameraFiles.count,
        ]
        if let s = setup() {
            out["camera"] = s.displayName
            out["ssid"] = s.ssid
            out["family"] = s.family.rawValue
            out["needs_parked_to_list"] = s.listingNeedsPlayback
        }
        if let r = sync.recording { out["recording"] = r }
        if let last = sync.lastSync { out["last_sync"] = last.dashcamISO }
        if let sd = sync.sd {
            out["sd_ok"] = sd.ok
            if let free = sd.freeBytes { out["sd_free_gb"] = (Double(free) / 1e9 * 10).rounded() / 10 }
            if let total = sd.totalBytes { out["sd_total_gb"] = (Double(total) / 1e9 * 10).rounded() / 10 }
        }
        out["newest_clips"] = sync.cameraFiles.prefix(5).map {
            ["path": $0.path, "kind": $0.kind.rawValue, "lens": $0.lens.rawValue, "start": $0.start.dashcamISO]
        }
        return out
    }

    private func camera() throws -> DashcamCamera {
        guard let setup = setup() else { throw DashcamError.unsupported("No dashcam is set up yet — add it in Devices.") }
        guard wifi() else { throw DashcamError.notConnected }
        guard let cam = sync.cameraFactory(setup) else {
            throw DashcamError.unsupported("This dashcam family (\(setup.family.rawValue)) isn't supported yet")
        }
        return cam
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "dashcam_get_status":
            return snapshot()
        case "dashcam_sync":
            _ = try camera()
            let report = await sync.syncNow()
            return ["ok": true, "listed": report.listed, "gps_read": report.gps, "thumbnails": report.thumbs,
                    "downloaded": report.downloaded, "waiting_for_park": sync.phase == .waitingForPark,
                    "phase": sync.phase.label]
        case "dashcam_lock_clip":
            try await camera().lock()
            // The locked copy appears on the card once the camera closes the clip.
            Task { try? await Task.sleep(for: .seconds(20)); await self.sync.syncNow() }
            return ["ok": true, "message": "Locked — it will be pulled and uploaded as an event."]
        case "dashcam_snapshot":
            let path = try await camera().snapshot()
            Task { try? await Task.sleep(for: .seconds(3)); await self.sync.syncNow() }
            var out: [String: Any] = ["ok": true, "message": "Photo taken; it will appear in the dashcam library."]
            if let path { out["path"] = path }
            return out
        case "dashcam_set_recording":
            guard let on = args["enabled"] as? Bool else { throw DeviceError.badArgument("enabled must be true or false") }
            let cam = try camera()
            do {
                try await cam.setRecording(on)
            } catch {
                // The A4 answers "set fail" when it's already in that state: what counts is the state it's in.
                guard (try? await cam.isRecording()) == on else { throw error }
            }
            let now = try? await cam.isRecording()
            sync.noteRecording(now ?? on)
            return ["ok": true, "recording": now ?? on]
        case "dashcam_get_settings":
            let items = try await camera().settings()
            return ["settings": items.map { item -> [String: Any] in
                var row: [String: Any] = ["key": item.name, "value": item.value ?? NSNull()]
                if let label = item.currentLabel { row["label"] = label }
                if !item.options.isEmpty { row["options"] = item.options.map { ["code": $0.code, "label": $0.label] } }
                if let range = item.range { row["range"] = range }
                return row
            }]
        case "dashcam_set_setting":
            guard let key = args["key"] as? String, !key.isEmpty else { throw DeviceError.badArgument("key is required") }
            guard let raw = args["value"].map({ "\($0)" }), !raw.isEmpty else { throw DeviceError.badArgument("value is required") }
            let cam = try camera()
            let items = try await cam.settings()
            guard let item = items.first(where: { $0.name == key }) else {
                throw DeviceError.badArgument("unknown setting \(key); call dashcam_get_settings")
            }
            let code = Self.resolve(raw, in: item)
            guard let code else {
                throw DeviceError.badArgument("\(key) takes one of: " + item.options.map { "\($0.code) (\($0.label))" }.joined(separator: ", "))
            }
            try await cam.set(key, code)
            return ["ok": true, "key": key, "value": code, "label": item.options.first { $0.code == code }?.label ?? code]
        case "dashcam_sd_info":
            let sd = try await camera().sdInfo()
            var out: [String: Any] = ["ok": sd.ok]
            if let t = sd.totalBytes { out["total_bytes"] = t }
            if let f = sd.freeBytes { out["free_bytes"] = f }
            return out
        case "dashcam_format_sd":
            guard args["confirm"] as? Bool == true else {
                throw DeviceError.badArgument("formatting erases every clip on the card — pass confirm=true to proceed")
            }
            try await camera().format()
            return ["ok": true, "message": "SD card formatted."]
        case "dashcam_delete_file":
            guard args["confirm"] as? Bool == true else {
                throw DeviceError.badArgument("deleting removes the file from the card — pass confirm=true to proceed")
            }
            guard let path = args["path"] as? String, !path.isEmpty else { throw DeviceError.badArgument("path is required") }
            let cam = try camera()
            // A full camera path (from the library) is deleted as is — no listing, which playback-only
            // firmware refuses outside playback mode. A bare name is looked up in the last listing.
            let target: DashcamFile
            if path.hasPrefix("/") {
                target = sync.cameraFiles.first { $0.path == path }
                    ?? DashcamFile(path: path, kind: .normal, lens: .front, start: Date(), durationS: 0, size: 0)
            } else if let hit = sync.cameraFiles.first(where: { $0.name == path }) {
                target = hit
            } else {
                throw DeviceError.badArgument("\(path) is not in the last listing — give the full path")
            }
            try await cam.delete(target)
            return ["ok": true, "deleted": target.path]
        case "dashcam_set_wifi":
            let ssid = (args["ssid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let password = (args["password"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard ssid != nil || password != nil else { throw DeviceError.badArgument("give an ssid and/or a password") }
            if let password, password.count < 8 { throw DeviceError.badArgument("Wi‑Fi passwords need 8+ characters") }
            guard var current = setup() else { throw DashcamError.notConnected }
            let cam = try camera()
            // The camera may apply each change at once and drop the link, so remember each part the
            // moment it is accepted. The old saved network is left alone (harmless once unused).
            if let ssid {
                try await cam.setWiFi(ssid: ssid, password: nil)
                current.ssid = ssid
                DashcamSetupStore.save(current)
            }
            if let password {
                do {
                    try await cam.setWiFi(ssid: nil, password: password)
                    DashcamSetupStore.password = password
                } catch where ssid != nil {
                    Task { try? await DashcamWiFi.shared.save(ssid: current.ssid, password: DashcamSetupStore.password) }
                    return ["ok": false, "ssid": current.ssid,
                            "message": "The name changed but the password didn't (the camera dropped the link). Rejoin it and set the password again."]
                }
            }
            let saved = current
            Task { try? await DashcamWiFi.shared.save(ssid: saved.ssid, password: DashcamSetupStore.password) }
            return ["ok": true, "ssid": current.ssid, "message": "The dashcam restarts its Wi‑Fi; the phone rejoins on its own."]
        case "dashcam_fetch_range":
            guard let from = (args["from"] as? String).flatMap(Self.parseTime),
                  let to = (args["to"] as? String).flatMap(Self.parseTime), to >= from else {
                throw DeviceError.badArgument("from and to must be ISO-8601 times with from ≤ to")
            }
            let matched = await sync.fetch(from: from, to: to)
            return ["ok": true, "matched": matched, "on_camera_wifi": wifi(),
                    "message": wifi() ? "Pulling now." : "Will pull next time the phone is on the dashcam's Wi‑Fi."]
        default:
            throw DeviceError.unknownCommand(name)
        }
    }

    /// A value given as the code or the label (case-insensitive).
    static func resolve(_ raw: String, in item: DashcamSettingItem) -> String? {
        if item.options.isEmpty { return raw }
        if item.options.contains(where: { $0.code == raw }) { return raw }
        return item.options.first { $0.label.caseInsensitiveCompare(raw) == .orderedSame }?.code
    }

    static func parseTime(_ s: String) -> Date? {
        if let d = Date.dashcamISO(s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

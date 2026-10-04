import SwiftUI

/// The dashcam on the car's screen: the phone's Dashcam page (status, Controls,
/// Sync, cloud backup, the clip library, Drives, Settings) as lists, with the
/// same rules for what each clip offers. No video, maps or typing — those stay
/// on the phone.
extension CarPlayScreens {

    // MARK: Dashcam page

    static func dashcam(_ d: CarPlayDashcamInput) -> [CarPlaySection] {
        var status = [CarPlayRow(id: "status", title: d.onCamera ? d.phaseLabel : "Away from the camera",
                                 detail: d.subtitle, symbol: d.onCamera ? "wifi" : "wifi.slash",
                                 tint: d.onCamera ? .success : .muted)]
        if d.onCamera, let rec = d.recording {
            let free = d.sdFreeBytes.map { String(format: " · %.1f GB free", Double($0) / 1e9) } ?? ""
            status.append(CarPlayRow(id: "camera", title: "Camera", detail: (rec ? "Recording" : "Stopped") + free,
                                     symbol: rec ? "record.circle" : "stop.circle", tint: rec ? .danger : .muted))
        }
        if let dl = d.downloading {
            status.append(CarPlayRow(id: "downloading", title: "Downloading \(dl.name)", detail: percent(dl.done, dl.total),
                                     symbol: "arrow.down.circle", tint: .accent))
        }
        if let up = d.uploading {
            status.append(CarPlayRow(id: "uploading", title: "Uploading to the cloud",
                                     detail: percent(up.done, up.total) + (d.pendingUploads > 0 ? " · \(d.pendingUploads) waiting" : ""),
                                     symbol: "arrow.up.circle", tint: .accent))
        }
        var sections = [CarPlaySection(title: nil, rows: status)]

        if d.onCamera {
            var controls = [
                CarPlayRow(id: "rec", title: d.recording == false ? "Record" : "Stop recording",
                           symbol: d.recording == false ? "record.circle" : "stop.circle",
                           tint: d.recording == false ? .accent : .danger, action: .dashcam(.record)),
                CarPlayRow(id: "photo", title: "Take a photo", symbol: "camera", tint: .accent, action: .dashcam(.photo)),
                CarPlayRow(id: "lock", title: "Lock this clip", detail: "Keeps it from being recorded over",
                           symbol: "lock", tint: .amber, action: .dashcam(.lock)),
            ]
            controls.append(CarPlayRow(id: "live", title: "Live view",
                                       detail: d.parked ? "The camera's picture, every 2 seconds" : "Only while parked",
                                       symbol: "video", tint: .accent, enabled: d.parked, action: .push(.live)))
            if let mic = d.mic {
                controls.append(CarPlayRow(id: "mic", title: mic.on ? "Mic on" : "Mic off", detail: mic.on ? "Tap to mute" : "Tap to record sound",
                                           symbol: mic.on ? "mic" : "mic.slash", tint: mic.on ? .accent : .muted,
                                           action: .dashcam(.mic(!mic.on))))
            }
            sections.append(CarPlaySection(title: "Controls", rows: controls))
        }

        var actions = [CarPlayRow(id: "sync", title: "Sync now", detail: d.passActive ? "Syncing…" : nil,
                                  symbol: "arrow.triangle.2.circlepath", enabled: d.onCamera && !d.passActive,
                                  action: .dashcam(.syncNow))]
        if !d.onCamera {
            actions.append(CarPlayRow(id: "reconnect", title: "Reconnect",
                                      detail: d.canReconnect ? "Join the camera's Wi‑Fi" : "Join it once from your iPhone",
                                      symbol: "wifi", enabled: d.canReconnect, action: .dashcam(.reconnect)))
        }
        actions.append(CarPlayRow(id: "backup", title: "Cloud backup",
                                  detail: [d.cloudBackupOn ? "On — tap to pause" : "Paused — tap to resume", d.uploadNote]
                                    .compactMap { $0 }.joined(separator: " · "),
                                  symbol: d.cloudBackupOn ? "icloud" : "icloud.slash", tint: d.cloudBackupOn ? .accent : .amber,
                                  action: .dashcam(.cloudBackup(!d.cloudBackupOn))))
        actions.append(CarPlayRow(id: "drives", title: "Drives", symbol: "car", action: .push(.drives)))
        actions.append(CarPlayRow(id: "settings", title: "Settings", symbol: "gearshape", action: .push(.dashcamSettings)))
        sections.append(CarPlaySection(title: nil, rows: actions))

        var clips = d.clips.map { clipRow($0, downloading: d.downloading, uploading: d.uploading) }
        if clips.isEmpty {
            clips = [CarPlayRow(id: "noclips", title: d.libraryError.map { "Couldn't load clips: \($0)" } ?? "No clips")]
        }
        if d.canLoadMore { clips.append(CarPlayRow(id: "more", title: "Load more", symbol: "ellipsis", action: .dashcam(.loadMore))) }
        sections.append(CarPlaySection(title: "Clips · \(d.filter.label)", rows: clips))
        return sections
    }

    static func clipRow(_ clip: DashcamServerClip, downloading: (name: String, done: Int64, total: Int64)? = nil,
                        uploading: (clipID: String, done: Int64, total: Int64)? = nil) -> CarPlayRow {
        let status = DashcamClipStatus.of(clip, uploadingID: uploading?.clipID)
        let transfer = DashcamClipTransfer.of(clip, downloading: downloading, uploading: uploading)
        var title = "\(clip.start.formatted(date: .omitted, time: .shortened)) · \(clip.kind.label)"
        if clip.lens != .front { title += " · \(clip.lens.rawValue.capitalized)" }
        return CarPlayRow(id: "clip:\(clip.id)", title: title,
                          detail: [status.label, transfer?.label].compactMap { $0 }.joined(separator: " · "),
                          symbol: status.symbol, tint: tint(status.tint),
                          clipThumbID: clip.hasThumb ? clip.id : nil, action: .push(.clip(id: clip.id)))
    }

    // MARK: Live view

    /// The live screen's rows (its picture is the header): status, and the other lens.
    static func live(status: String, otherLens: String, canSwitch: Bool) -> [CarPlaySection] {
        var rows = [CarPlayRow(id: "liveStatus", title: status, symbol: "video", tint: .accent)]
        if canSwitch {
            rows.append(CarPlayRow(id: "switchLens", title: "Switch to the \(otherLens.lowercased()) camera",
                                   symbol: "camera.rotate", action: .dashcam(.switchLens)))
        }
        return [CarPlaySection(title: nil, rows: rows)]
    }

    // MARK: Clip

    static func clip(_ clip: DashcamServerClip, topMps: Double?) -> CarPlayInfo {
        let places = DashcamClipPlaces.of(clip)
        let where_ = [places.card ? "SD card" : nil, places.phone ? "Phone" : nil, places.cloud ? "Cloud" : nil].compactMap { $0 }
        var items = [
            CarPlayInfoItem(title: "When", detail: clip.start.formatted(date: .abbreviated, time: .shortened)),
            CarPlayInfoItem(title: "Kind", detail: clip.kind.label),
            CarPlayInfoItem(title: "Lens", detail: clip.lens.rawValue.capitalized),
        ]
        if clip.kind != .photo { items.append(CarPlayInfoItem(title: "Length", detail: DashcamSpeed.duration(clip.durationS))) }
        items.append(CarPlayInfoItem(title: "Size", detail: ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file)))
        if let topMps { items.append(CarPlayInfoItem(title: "Top speed", detail: "\(DashcamSpeed.text(topMps)) mph")) }
        items.append(CarPlayInfoItem(title: "Where", detail: where_.isEmpty ? "Nowhere" : where_.joined(separator: " · ")))
        items.append(CarPlayInfoItem(title: "Status", detail: DashcamClipStatus.of(clip).label))
        for (name, dest) in clip.destinations.sorted(by: { $0.key < $1.key }) {
            items.append(CarPlayInfoItem(title: name, detail: dest.error.map { "\(dest.state): \($0)" } ?? dest.state))
        }

        var actions: [CarPlayRow] = []
        if clip.onCamera && clip.phoneState != "local" && !clip.uploaded {      // the phone's "Pull from camera"
            actions.append(CarPlayRow(id: "download", title: "Download", action: .clip(id: clip.id, .download)))
        }
        if clip.failed { actions.append(CarPlayRow(id: "retry", title: "Retry upload", action: .clip(id: clip.id, .retryUpload))) }
        actions.append(CarPlayRow(id: "delete", title: "Delete…", action: .clip(id: clip.id, .delete)))
        return CarPlayInfo(title: "\(clip.kind.label) · \(clip.start.formatted(date: .omitted, time: .shortened))",
                           items: items, actions: actions)
    }

    /// The phone's Delete… menu: only the places the clip is, then Everywhere.
    static func clipDeleteOptions(_ clip: DashcamServerClip) -> [(title: String, places: Set<DashcamLibraryModel.Place>)] {
        let places = DashcamClipPlaces.of(clip)
        var out: [(String, Set<DashcamLibraryModel.Place>)] = []
        if places.phone { out.append(("From this phone", [.phone])) }
        if places.cloud || clip.uploading { out.append(("From the cloud", [.cloud])) }
        if clip.onCamera { out.append(("From the dashcam", [.camera])) }
        out.append(("Everywhere", [.phone, .cloud, .camera]))
        return out.map { (title: $0.0, places: $0.1) }
    }

    // MARK: Drives

    static func drives(_ drives: [DashcamDrive], error: String? = nil,
                       now: Date = Date(), calendar: Calendar = .current) -> [CarPlaySection] {
        if drives.isEmpty, let error {
            return [CarPlaySection(title: nil, rows: [CarPlayRow(id: "drivesError", title: "Couldn't load drives", detail: error,
                                                                 symbol: "exclamationmark.triangle", tint: .amber)])]
        }
        guard !drives.isEmpty else {
            return [CarPlaySection(title: nil, rows: [CarPlayRow(id: "nodrives", title: "No drives yet",
                                                                 detail: "Each sync reads the GPS in every clip and joins them into drives.")])]
        }
        let week = DashcamDriveStats.week(drives, now: now)
        let summary = CarPlayRow(id: "week", title: "Drives",
                                 detail: "\(week.count) drive\(week.count == 1 ? "" : "s") · \(DashcamSpeed.miles(week.distanceM)) · top \(DashcamSpeed.text(week.topMps)) mph",
                                 symbol: "car.fill", tint: .accent)
        return [CarPlaySection(title: "Last 7 days", rows: [summary])]
            + DashcamDriveStats.byDay(drives, calendar: calendar, now: now).map { day, items in
                CarPlaySection(title: day, rows: items.map {
                    CarPlayRow(id: "drive:\($0.id)", title: DashcamDriveStats.title($0), detail: DashcamDriveStats.detail($0),
                               symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .accent)
                })
            }
    }

    // MARK: Settings

    static let phoneCapChoices = [5, 10, 20, 50, 100, 200]

    static func dashcamSettings(_ s: CarPlayDashcamSettingsInput) -> [CarPlaySection] {
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
        var sections = [CarPlaySection(title: "Auto sync", rows: [
            CarPlayRow(id: "la", title: "Lock Screen progress", detail: onOff(s.liveActivity), action: .dashcam(.liveActivity(!s.liveActivity))),
            CarPlayRow(id: "auto", title: "Auto download", detail: onOff(s.autoSync), action: .dashcam(.autoSync(!s.autoSync))),
        ])]
        if s.rulesLoaded {
            let r = s.rules
            sections.append(CarPlaySection(title: "Sync rules", rows: [
                CarPlayRow(id: "normal", title: "Normal footage", detail: r.normal.label, action: .dashcam(.chooseRule(.normal))),
                CarPlayRow(id: "normalWhen", title: "Pull when", detail: r.normalWhen.label, action: .dashcam(.chooseRule(.normalWhen))),
                CarPlayRow(id: "cap", title: "Phone space", detail: "\(r.phoneCapGB) GB", action: .dashcam(.chooseRule(.phoneCap))),
                CarPlayRow(id: "keep", title: "Keep clips on the phone", detail: onOff(r.keepOnPhone), action: .dashcam(.toggleRule(.keepOnPhone))),
            ]))
            var upload = [CarPlayRow(id: "upload", title: "Upload clips", detail: onOff(r.upload), action: .dashcam(.toggleRule(.upload)))]
            if r.upload {
                upload.append(CarPlayRow(id: "data", title: "Over mobile data", detail: r.uploadData.label, action: .dashcam(.chooseRule(.uploadData))))
                upload.append(CarPlayRow(id: "uploadWhen", title: "Upload when", detail: r.uploadWhen.label, action: .dashcam(.chooseRule(.uploadWhen))))
            }
            sections.append(CarPlaySection(title: "Upload to the cloud", rows: upload))
        } else {
            sections.append(CarPlaySection(title: "Sync rules", rows: [CarPlayRow(id: "rulesLoading", title: "Loading the rules from the server…")]))
        }
        if s.onCamera {
            let items = s.cameraItems.filter { !$0.options.isEmpty }.map {
                CarPlayRow(id: "setting:\($0.name)", title: DashcamCameraSettings.title($0.name), detail: $0.currentLabel,
                           action: .dashcam(.chooseSetting($0.name)))
            }
            sections.append(CarPlaySection(title: "Camera", rows: items.isEmpty ? [CarPlayRow(id: "camLoading", title: "Reading the camera's settings…")] : items))
        } else {
            sections.append(CarPlaySection(title: "Camera", rows: [CarPlayRow(id: "camAway", title: "Camera settings",
                                                                              detail: "Show up on the dashcam's Wi‑Fi (start the car)", enabled: false)]))
        }
        let free: String
        if let sd = s.sd, let f = sd.freeBytes, let t = sd.totalBytes { free = String(format: "%.1f of %.1f GB", Double(f) / 1e9, Double(t) / 1e9) }
        else { free = s.sd?.ok == false ? "No card" : "–" }
        sections.append(CarPlaySection(title: "SD card & clock", rows: [
            CarPlayRow(id: "free", title: "Free", detail: free, symbol: "sdcard"),
            CarPlayRow(id: "clock", title: "Sync the camera's clock", symbol: "clock", enabled: s.onCamera, action: .dashcam(.syncClock)),
        ]))
        return sections
    }

    /// The choices for a rule, its current value ticked.
    static func ruleOptions(_ key: CarPlayRuleKey, _ r: DashcamRules) -> [(title: String, checked: Bool)] {
        switch key {
        case .normal: return DashcamRules.Normal.allCases.map { ($0.label, $0 == r.normal) }
        case .normalWhen: return DashcamRules.When.allCases.map { ($0.label, $0 == r.normalWhen) }
        case .uploadWhen: return DashcamRules.When.allCases.map { ($0.label, $0 == r.uploadWhen) }
        case .uploadData: return DashcamRules.UploadData.allCases.map { ($0.label, $0 == r.uploadData) }
        case .phoneCap: return phoneCapChoices.map { ("\($0) GB", $0 == r.phoneCapGB) }
        case .keepOnPhone: return [("On", r.keepOnPhone), ("Off", !r.keepOnPhone)]
        case .upload: return [("On", r.upload), ("Off", !r.upload)]
        }
    }

    /// The rules with choice `choice` (an index into `ruleOptions`) applied.
    static func applyRule(_ key: CarPlayRuleKey, choice: Int, to rules: DashcamRules) -> DashcamRules {
        var r = rules
        switch key {
        case .normal: if DashcamRules.Normal.allCases.indices.contains(choice) { r.normal = DashcamRules.Normal.allCases[choice] }
        case .normalWhen: if DashcamRules.When.allCases.indices.contains(choice) { r.normalWhen = DashcamRules.When.allCases[choice] }
        case .uploadWhen: if DashcamRules.When.allCases.indices.contains(choice) { r.uploadWhen = DashcamRules.When.allCases[choice] }
        case .uploadData: if DashcamRules.UploadData.allCases.indices.contains(choice) { r.uploadData = DashcamRules.UploadData.allCases[choice] }
        case .phoneCap: if phoneCapChoices.indices.contains(choice) { r.phoneCapGB = phoneCapChoices[choice] }
        case .keepOnPhone: r.keepOnPhone = choice == 0
        case .upload: r.upload = choice == 0
        }
        return r
    }

    // MARK: Helpers

    static func percent(_ done: Int64, _ total: Int64) -> String {
        total > 0 ? "\(Int((Double(done) / Double(total) * 100).rounded()))%" : "Starting…"
    }

    /// The library chip's colour, as one of CarPlay's tints.
    static func tint(_ color: Color) -> CarPlayTint {
        switch color {
        case JcTheme.danger: return .danger
        case JcTheme.success: return .success
        case JcTheme.amber: return .amber
        case JcTheme.accent: return .accent
        default: return .muted
        }
    }
}

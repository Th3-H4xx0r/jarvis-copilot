import AVFAudio
import CarPlay
import Combine
import Foundation
import Observation

/// Owns the car's screen: the Voice and Wearables tabs, the screens pushed over
/// them (never deeper than three), and what every row does. State comes
/// from the same stores the phone uses; the screens themselves are the pure
/// builders in `CarPlayScreens`.
@available(iOS 26.4, *)
@MainActor
final class CarPlayCoordinator: NSObject, CPInterfaceControllerDelegate {
    private let ui: CPInterfaceController
    private let voiceTab = CPListTemplate(title: "Voice", sections: [])
    private let wearablesTab = CPListTemplate(title: "Wearables", sections: [])
    private var tabBar: CPTabBarTemplate?
    private var stack: [(screen: CarPlayScreen, template: CPTemplate)] = []
    /// The Voice tab's orb, state and Talk; off the tab while the voice card is open.
    private var voiceHeaderView: CPListTemplateDetailsHeader?
    /// What the Voice tab's orb and buttons last showed (rebuilt only when it changes).
    private var voiceHeaderKey: String?
    /// Apple's voice card over the bottom of the screen while talking (the Voice tab keeps the text above it).
    private(set) lazy var voice = CarPlayVoiceScreen(ui: ui)

    /// The car's own library page (filter, paging), apart from the phone's.
    private let library = DashcamLibraryModel()
    private var drives: [DashcamDrive] = []
    private var cameraItems: [DashcamSettingItem] = []
    private var mic: DashcamMic?
    private var clipDetails: [String: (clip: DashcamServerClip, topMps: Double?)] = [:]
    private var reconnectNote: String?
    /// Why the drives list couldn't load (shown instead of an empty list).
    private var drivesError: String?
    /// A camera Wi‑Fi password is saved (read once per dashcam visit, not per refresh: it's a Keychain read).
    private var hasWifiPassword = false
    private var sectionsCache = CarPlaySectionsCache()
    private var infoCache: [ObjectIdentifier: CarPlayInfo] = [:]
    private var watchingDashcam = false
    /// The live view while its screen is open: the phone's live session, its frames
    /// decoded into stills, and the 2-second refresh.
    private var live: (model: DashcamLiveModel, decoder: DashcamStillDecoder, ticker: Task<Void, Never>)?
    private var refreshPending = false
    private var running = false
    /// CarPlay has the tabs (setRootTemplate finished). Changes made to them before
    /// this can be lost, so the voice card waits for it.
    private var rootReady = false
    private var voiceWaiting = false
    private var cancellables: Set<AnyCancellable> = []

    private var sync: DashcamSync { .shared }
    private var wifi: DashcamWiFi { .shared }
    private var paired: Bool { JarvisAPI.shared.isPaired }

    init(interfaceController: CPInterfaceController) {
        ui = interfaceController
        super.init()
        ui.delegate = self
    }

    // MARK: Lifecycle

    func start() {
        running = true
        voiceTab.tabImage = UIImage(systemName: "waveform")
        voiceHeaderView = voiceHeader()
        voiceTab.listHeader = voiceHeaderView
        wearablesTab.tabImage = UIImage(systemName: "car")
        let tabs = CPTabBarTemplate(templates: [voiceTab, wearablesTab])
        tabBar = tabs
        ui.setRootTemplate(tabs, animated: false) { [weak self] ok, _ in
            cpDiag("root ready ok=\(ok)")
            guard let self, self.running else { return }
            self.rootReady = true
            if self.voiceWaiting { self.voiceWaiting = false; self.handle(.startVoice) }
        }
        refresh()
        observeStores()
        subscribeToDevices()
        WidgetModelSnapshots.refreshIfNeeded()    // the dashboard widget's orb picture
        voice.onShowingChange = { [weak self] in self?.refresh() }
        voice.attach()
        // Render the voice orb's frames now, not on the first Talk tap.
        Task {
            try? await Task.sleep(for: .seconds(2))
            // The voice screen's loops (CarPlay's 150 pt limit) and the Voice tab header's.
            if running { await OrbFrames.prewarm(sizes: [OrbFrames.side, voiceHeaderSide]) }
        }
    }

    func stop() {
        running = false
        cancellables.removeAll()
        if watchingDashcam { sync.watchStatus(false); watchingDashcam = false }
        stopLive()
        voice.stop()
        OrbFrames.clear()
    }

    // MARK: Refresh

    /// Store changes arrive in bursts (a sync pass moves several fields at once):
    /// one rebuild a second is plenty for a screen you glance at.
    private func scheduleRefresh() {
        guard running, !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private func refresh() {
        guard running else { return }
        show(paired ? CarPlayScreens.voiceTab(conversation, speaking: VoiceStore.shared.state == .speaking)
                    : CarPlayScreens.notPaired, in: voiceTab)
        updateVoiceHeader()
        show(paired ? CarPlayScreens.wearablesTab(carDevices.map(\.row)) : CarPlayScreens.notPaired, in: wearablesTab)
        for entry in stack { update(entry.template, for: entry.screen) }
    }

    /// Rebuild a list only when what it shows changed.
    private func show(_ sections: [CarPlaySection], in list: CPListTemplate) {
        guard sectionsCache.changed(ObjectIdentifier(list), sections) else { return }
        list.updateSections(render(sections))
    }

    private func render(_ sections: [CarPlaySection]) -> [CPListSection] {
        CarPlayRenderer.sections(sections) { [weak self] action in self?.handle(action) }
    }

    /// `@Observable` stores: re-arm after every change (Observation fires once).
    private func observeStores() {
        guard running else { return }
        withObservationTracking {
            let v = VoiceStore.shared
            _ = v.state; _ = v.error
            _ = v.userTranscript; _ = v.livePartial; _ = v.assistantText; _ = v.spokenWords
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
                self?.observeStores()
            }
        }
    }

    /// `ObservableObject` stores: which devices exist, the dashcam, the car's library page.
    private func subscribeToDevices() {
        let feeds: [AnyPublisher<Void, Never>] = [
            DeviceRegistry.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            sync.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            wifi.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            library.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(feeds)
            .sink { [weak self] in self?.scheduleRefresh() }
            .store(in: &cancellables)
        // The dashcam screen polls the camera only while the phone is on its Wi‑Fi.
        wifi.$onCamera
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self, self.watchingDashcam else { return }
                self.sync.watchStatus(on)
                if on { Task { self.mic = await DashcamControls.mic() } }
            }
            .store(in: &cancellables)
    }

    // MARK: Snapshots of the stores

    private var voiceStateText: String {
        let v = VoiceStore.shared
        return CarPlayScreens.voiceStateText(state: v.state, error: v.error,
                                             micAllowed: AVAudioApplication.shared.recordPermission != .denied)
    }

    private var voiceHeaderSide: CGFloat {
        if #available(iOS 27.0, *) { return CPThumbnailImage.maximumImageSize(forAspectRatio: 1).height }
        return 240
    }

    /// The Voice tab IS the voice screen (no pop-up): the phone's orb, Jarvis's state,
    /// the conversation, and Talk / Mute / Stop.
    private func voiceHeader() -> CPListTemplateDetailsHeader? {
        guard let orb = OrbFrames.animated(for: .listening, size: voiceHeaderSide) ?? OrbFrames.still(size: voiceHeaderSide) else { return nil }
        return CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: orb), title: "Jarvis",
                                           subtitle: voiceStateText, bodyVariants: [], actionButtons: [])
    }

    /// The header follows the session: the orb for its state, Jarvis's state, what you
    /// said (dim) and the reply with its spoken words lit, and the buttons that fit now.
    private func updateVoiceHeader() {
        let attached = CarPlayScreens.showsVoiceHeader(cardOpen: voice.isShowing) ? voiceHeaderView : nil
        if voiceTab.listHeader !== attached {
            cpDiag("listHeader -> \(attached == nil ? "nil" : "header") card=\(voice.isShowing) rootReady=\(rootReady)")
            voiceTab.listHeader = attached
        }
        guard let header = voiceHeaderView else { return }
        let v = VoiceStore.shared
        let subtitle = paired ? voiceStateText : "Pair Jarvis on your iPhone"
        if header.subtitle != subtitle { header.subtitle = subtitle }

        let buttons = paired ? CarPlayScreens.voiceButtons(active: v.isActive, muted: v.muted,
                                                           pushToTalk: v.mode == .quality && v.state == .listening) : []
        let key = "\(v.state.rawValue)|\(buttons)"
        guard key != voiceHeaderKey else { return }
        voiceHeaderKey = key
        if let orb = OrbFrames.animated(for: v.state, size: voiceHeaderSide) { header.thumbnail = CPThumbnailImage(image: orb) }
        header.actionButtons = buttons.map(voiceButton)
    }

    private func voiceButton(_ kind: CarPlayVoiceButton) -> CPButton {
        let store = VoiceStore.shared
        let (symbol, title): (String, String)
        switch kind {
        case .talk: (symbol, title) = ("mic.fill", "Talk")
        case .mute: (symbol, title) = ("mic.slash.fill", "Mute")
        case .unmute: (symbol, title) = ("mic.fill", "Unmute")
        case .send: (symbol, title) = ("arrow.up.circle.fill", "Send")
        case .stop: (symbol, title) = ("stop.fill", "Stop")
        }
        let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { [weak self] _ in
            switch kind {
            case .talk: self?.handle(.startVoice)
            case .mute, .unmute: store.toggleMute(); self?.refresh()
            case .send: store.finishSpeaking()
            case .stop: self?.stopVoice()
            }
        }
        button.title = title
        return button
    }

    /// End the conversation (Stop, the car left Jarvis, or disconnected).
    func stopVoice() {
        guard VoiceStore.shared.isActive else { return }
        Task { await VoiceStore.shared.stopAll() }
    }

    /// The conversation as the phone shows it (what you said, Jarvis's reply).
    private var conversation: CarPlayVoiceText? {
        let v = VoiceStore.shared
        return CarPlayScreens.voiceText(heard: v.userTranscript.isEmpty ? v.livePartial : v.userTranscript,
                                        reply: voicePlainSpeech(v.assistantText), spokenWords: v.spokenWords)
    }

    /// Every device Jarvis knows whose type opted into the car (`carEnabled`).
    private var carDevices: [(row: CarPlayCarDevice, device: any WearableDevice)] {
        DeviceRegistry.shared.devices.filter(\.carEnabled).map { device in
            if device is DashcamDevice {
                let status = [wifi.onCamera ? sync.phase.label : "Away",
                              wifi.onCamera && sync.recording == true ? "Recording" : nil,
                              sync.pendingUploads > 0 ? "\(sync.pendingUploads) to upload" : nil].compactMap { $0 }
                return (CarPlayCarDevice(id: device.deviceID, name: DashcamSetupStore.load()?.displayName ?? "Dashcam",
                                         status: status.joined(separator: " · "), connected: device.isConnected, isDashcam: true),
                        device)
            }
            let name = (device.snapshot()["name"] as? String) ?? type(of: device).model
            return (CarPlayCarDevice(id: device.deviceID, name: name, status: device.isConnected ? "Connected" : "Not connected",
                                     connected: device.isConnected, isDashcam: false), device)
        }
    }

    private var dashcamInput: CarPlayDashcamInput {
        CarPlayDashcamInput(
            onCamera: wifi.onCamera, phaseLabel: sync.phase.label, recording: sync.recording,
            sdFreeBytes: sync.sd?.freeBytes,
            subtitle: (!wifi.onCamera ? reconnectNote : nil)
                ?? DashcamStatusText.subtitle(lastSync: sync.lastSync, pendingUploads: sync.pendingUploads,
                                              queuedDownloads: sync.queuedDownloads),
            downloading: sync.downloading, uploading: sync.uploading,
            cloudBackupOn: sync.rules.upload, uploadNote: sync.rules.upload ? sync.uploadNote : nil,
            passActive: sync.passActive, mic: mic, canReconnect: hasWifiPassword,
            filter: library.filter, clips: library.clips, canLoadMore: library.canLoadMore,
            libraryError: library.error, pendingUploads: sync.pendingUploads,
            parked: DashcamMotion.shared.isParked())
    }

    private var settingsInput: CarPlayDashcamSettingsInput {
        CarPlayDashcamSettingsInput(liveActivity: DashcamSyncBeacon.enabled, autoSync: sync.autoSync, rules: sync.rules,
                                    rulesLoaded: sync.rulesLoaded, onCamera: wifi.onCamera,
                                    cameraItems: cameraItems, sd: sync.sd)
    }

    private func clip(_ id: String) -> DashcamServerClip? {
        clipDetails[id]?.clip ?? library.clips.first { $0.id == id }
    }

    // MARK: Screens

    private func title(_ screen: CarPlayScreen) -> String {
        switch screen {
        case .dashcam: return DashcamSetupStore.load()?.displayName ?? "Dashcam"
        case .clip: return "Clip"
        case .drives: return "Drives"
        case .dashcamSettings: return "Dashcam settings"
        case .live: return "Live view"
        case .device(let id): return carDevices.first { $0.row.id == id }?.row.name ?? "Device"
        }
    }

    private func sections(_ screen: CarPlayScreen) -> [CarPlaySection]? {
        switch screen {
        case .dashcam: return CarPlayScreens.dashcam(dashcamInput)
        case .drives: return CarPlayScreens.drives(drives, error: drivesError)
        case .dashcamSettings: return CarPlayScreens.dashcamSettings(settingsInput)
        case .live: return CarPlayScreens.live(status: liveStatus, otherLens: live?.model.otherLensName ?? "Rear",
                                               canSwitch: live?.model.source?.canSwitch ?? false)
        case .clip, .device: return nil
        }
    }

    private func info(_ screen: CarPlayScreen) -> CarPlayInfo? {
        switch screen {
        case .clip(let id):
            guard let c = clip(id) else { return CarPlayInfo(title: "Clip", items: [CarPlayInfoItem(title: "Clip", detail: "Gone from the library")]) }
            return CarPlayScreens.clip(c, topMps: clipDetails[id]?.topMps)
        case .device(let id):
            guard let entry = carDevices.first(where: { $0.row.id == id }) else {
                return CarPlayInfo(title: "Device", items: [CarPlayInfoItem(title: "Status", detail: "No longer shared with Jarvis")])
            }
            return CarPlayScreens.carDevice(name: entry.row.name, connected: entry.row.connected, snapshot: entry.device.snapshot())
        default: return nil
        }
    }

    private func makeTemplate(_ screen: CarPlayScreen) -> CPTemplate {
        let handler: CarPlayRenderer.Handler = { [weak self] action in self?.handle(action) }
        if let info = info(screen) { return CarPlayRenderer.info(info, handler: handler) }
        let list = CPListTemplate(title: title(screen), sections: render(sections(screen) ?? []))
        if screen == .dashcam {
            list.trailingNavigationBarButtons = [CPBarButton(title: "Filter") { [weak self] _ in self?.chooseFilter() }]
        }
        if screen == .live, let placeholder = UIImage(systemName: "video") {
            list.listHeader = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: placeholder), title: "Live",
                                                          subtitle: "Connecting to the camera…", actionButtons: [])
        }
        return list
    }

    private func update(_ template: CPTemplate, for screen: CarPlayScreen) {
        if let list = template as? CPListTemplate, let sections = sections(screen) {
            show(sections, in: list)
        } else if let infoTemplate = template as? CPInformationTemplate, let info = info(screen),
                  infoCache[ObjectIdentifier(infoTemplate)] != info {
            infoCache[ObjectIdentifier(infoTemplate)] = info
            CarPlayRenderer.update(infoTemplate, with: info) { [weak self] action in self?.handle(action) }
        }
    }

    private func push(_ screen: CarPlayScreen) {
        // Root is depth 1; the next push is always exactly one deeper, never past 3.
        pruneStack()
        guard screen.depth <= CarPlayScreen.maxDepth, screen.depth == stack.count + 2 else { return }
        let template = makeTemplate(screen)
        stack.append((screen, template))
        ui.pushTemplate(template, animated: true, completion: nil)
        load(screen)
    }

    /// What a screen fetches when it opens; the store observers refresh it after.
    private func load(_ screen: CarPlayScreen) {
        switch screen {
        case .dashcam:
            watchingDashcam = true
            hasWifiPassword = DashcamSetupStore.password != nil
            sync.watchStatus(wifi.onCamera)
            Task { await library.reload() }
            if !sync.rulesLoaded { Task { await sync.refreshRules() } }
            if wifi.onCamera { Task { mic = await DashcamControls.mic(); refresh() } }
        case .clip(let id):
            Task {
                guard let detail = try? await DashcamAPI().clip(id) else { return }
                clipDetails[id] = (detail.clip, detail.fixes.compactMap(\.speed).max())
                refresh()
            }
        case .drives:
            Task {
                do {
                    drives = try await DashcamAPI().drives().sorted { $0.start > $1.start }
                    drivesError = nil
                } catch {
                    drivesError = error.localizedDescription
                }
                refresh()
            }
        case .dashcamSettings:
            Task {
                if !sync.rulesLoaded { await sync.refreshRules() }
                if wifi.onCamera { cameraItems = (try? await DashcamCameraSettings.load()) ?? [] }
                refresh()
            }
        case .live: startLive()
        case .device: break
        }
    }

    // MARK: Live view (still pictures, parked only)

    private var liveStatus: String {
        guard let model = live?.model else { return "Stopped" }
        switch model.status {
        case .connecting: return "Connecting to the camera…"
        case .playing: return "Live · \(model.lensName)"
        case .failed(let message): return message
        }
    }

    private func startLive() {
        guard live == nil else { return }
        guard DashcamMotion.shared.isParked() else {
            alert("Live view works while you're parked.")
            return
        }
        let model = DashcamLiveModel()
        let decoder = DashcamStillDecoder()
        model.frameSink = { decoder.decode($0) }
        let ticker = Task { @MainActor [weak self] in
            await model.open()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.liveTick()
            }
        }
        live = (model, decoder, ticker)
    }

    /// Every 2 s: a fresh picture — or stop, if the car started moving.
    private func liveTick() {
        guard let live else { return }
        guard DashcamMotion.shared.isParked() else {
            stopLive()
            if let screen = stack.last(where: { $0.screen == .live })?.template, ui.topTemplate === screen {
                ui.popTemplate(animated: true, completion: nil)
            }
            alert("Live view stopped — you're driving.")
            return
        }
        guard let header = (stack.last(where: { $0.screen == .live })?.template as? CPListTemplate)?.listHeader else { return }
        let side: CGFloat
        if #available(iOS 27.0, *) {
            side = CPThumbnailImage.maximumImageSize(forAspectRatio: 16.0 / 9.0).width
        } else {
            side = 480
        }
        if let picture = live.decoder.image(maxSide: side) { header.thumbnail = CPThumbnailImage(image: picture) }
        header.subtitle = liveStatus
        refresh()
    }

    private func stopLive() {
        guard let live else { return }
        live.ticker.cancel()
        live.model.close()            // also lets syncing carry on
        self.live = nil
    }

    // MARK: Actions

    func handle(_ action: CarPlayAction) {
        switch action {
        case .none: break
        case .push(let screen): push(screen)
        case .startVoice:
            guard paired else { alert("Pair Jarvis on your iPhone first."); return }
            cpDiag("startVoice rootReady=\(rootReady)")
            guard rootReady else { voiceWaiting = true; return }
            // The Voice tab is the voice screen: go there, then start listening.
            if tabBar?.selectedTemplate !== voiceTab || !stack.isEmpty {
                ui.popToRootTemplate(animated: false, completion: nil)
                tabBar?.select(voiceTab)
            }
            voice.start()
        case .dashcam(let command): run(command)
        case .clip(let id, let command): run(command, clipID: id)
        }
    }

    private func run(_ command: CarPlayDashcamCommand) {
        switch command {
        case .record: Task { alert(await DashcamControls.toggleRecording()) }
        case .photo: Task { alert(await DashcamControls.photo()) }
        case .lock: Task { alert(await DashcamControls.lock()) }
        case .mic(let on):
            guard let current = mic else { return }
            Task {
                let result = await DashcamControls.setMic(on, current)
                if result.ok { mic?.on = on }
                alert(result.note)
                refresh()
            }
        case .syncNow: Task { _ = await sync.syncNow() }
        case .reconnect:
            Task {
                do { try await wifi.reconnect(password: nil); reconnectNote = nil }
                catch { reconnectNote = error.localizedDescription }
                hasWifiPassword = DashcamSetupStore.password != nil
                refresh()
            }
        case .cloudBackup(let on): sync.setCloudBackup(on)
        case .loadMore: Task { await library.loadMore() }
        case .liveActivity(let on):
            DashcamSyncBeacon.enabled = on
            refresh()
        case .autoSync(let on):
            sync.autoSync = on
            // "Download everything" needs normal footage switched on too (as on the phone).
            if on, sync.rulesLoaded, sync.rules.normal == .off { saveRules(CarPlayScreens.applyRule(.normal, choice: 2, to: sync.rules)) }
        case .chooseRule(let key):
            sheet(ruleTitle(key), CarPlayScreens.ruleOptions(key, sync.rules)) { [weak self] choice in
                guard let self else { return }
                self.saveRules(CarPlayScreens.applyRule(key, choice: choice, to: self.sync.rules))
            }
        case .toggleRule(let key):
            let on = CarPlayScreens.ruleOptions(key, sync.rules).first?.checked ?? false
            saveRules(CarPlayScreens.applyRule(key, choice: on ? 1 : 0, to: sync.rules))
        case .chooseSetting(let name):
            guard let item = cameraItems.first(where: { $0.name == name }) else { return }
            let title = DashcamCameraSettings.title(name)
            sheet(title, item.options.map { ($0.label, $0.code == item.value) }) { [weak self] choice in
                guard let self, item.options.indices.contains(choice) else { return }
                Task {
                    do {
                        try await DashcamCameraSettings.set(name, item.options[choice].code)
                        self.cameraItems = (try? await DashcamCameraSettings.load()) ?? self.cameraItems
                        self.alert("\(title) changed.")
                    } catch { self.alert(error.localizedDescription) }
                    self.refresh()
                }
            }
        case .switchLens:
            if let model = live?.model { Task { await model.switchLens(); refresh() } }
        case .syncClock:
            Task {
                _ = await sync.syncNow()
                alert("Clock set from the phone.")
            }
        }
    }

    private func run(_ command: CarPlayClipCommand, clipID: String) {
        guard let clip = clip(clipID) else { return }
        switch command {
        case .download: alert(DashcamClipActions.pull(clip))
        case .retryUpload:
            Task {
                await DashcamClipActions.retryUpload(clip)
                await library.reload()
                alert("Upload retried.")
            }
        case .delete:
            let options = CarPlayScreens.clipDeleteOptions(clip)
            sheet("Delete this clip?", options.map { ($0.title, false) }, destructive: true) { [weak self] choice in
                guard let self, options.indices.contains(choice) else { return }
                Task {
                    let (done, failed) = await DashcamClipActions.delete(clip, options[choice].places)
                    await self.library.reload()
                    // Back off the clip's screen — unless the driver already left it.
                    if let clipScreen = self.stack.last(where: { $0.screen == .clip(id: clipID) })?.template,
                       self.ui.topTemplate === clipScreen {
                        self.ui.popTemplate(animated: true, completion: nil)
                    }
                    self.alert(failed.isEmpty ? "Deleted from the \(done.joined(separator: ", "))."
                                              : "Couldn't delete everywhere — " + failed.joined(separator: "; "))
                }
            }
        }
    }

    private func saveRules(_ rules: DashcamRules) {
        sync.rules = rules
        Task {
            if let failure = await sync.saveRules() { alert(failure) }
            sync.kickUploads()
        }
        refresh()
    }

    private func ruleTitle(_ key: CarPlayRuleKey) -> String {
        switch key {
        case .normal: return "Normal footage"
        case .normalWhen: return "Pull normal footage"
        case .phoneCap: return "Phone space for clips"
        case .keepOnPhone: return "Keep clips on the phone"
        case .upload: return "Upload clips"
        case .uploadData: return "Upload over mobile data"
        case .uploadWhen: return "Upload"
        }
    }

    private func chooseFilter() {
        let filters = DashcamLibraryModel.Filter.allCases
        sheet("Show", filters.map { ($0.label, $0 == library.filter) }) { [weak self] choice in
            guard let self, filters.indices.contains(choice) else { return }
            self.library.filter = filters[choice]          // reloads on its own
        }
    }

    // MARK: Alerts and choices

    /// One line and OK. Never over the voice screen — it owns the car's screen while talking.
    func alert(_ text: String) {
        guard running, !voice.isShowing else { return }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.ui.dismissTemplate(animated: true, completion: nil) },
        ])
        present(alert)
    }

    private func sheet(_ title: String, _ options: [(title: String, checked: Bool)], destructive: Bool = false,
                       pick: @escaping (Int) -> Void) {
        var actions = options.enumerated().map { index, option in
            CPAlertAction(title: (option.checked ? "✓ " : "") + option.title, style: destructive ? .destructive : .default) { [weak self] _ in
                self?.ui.dismissTemplate(animated: true, completion: nil)
                pick(index)
            }
        }
        actions.append(CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.ui.dismissTemplate(animated: true, completion: nil)
        })
        present(CPActionSheetTemplate(title: title, message: nil, actions: actions))
    }

    private func present(_ template: CPTemplate) {
        if ui.presentedTemplate != nil {
            ui.dismissTemplate(animated: false) { [weak self] _, _ in self?.ui.presentTemplate(template, animated: true, completion: nil) }
        } else {
            ui.presentTemplate(template, animated: true, completion: nil)
        }
    }

    /// Forget every pushed screen CarPlay no longer shows (Back, pop-to-root), and stop
    /// polling the camera once the dashcam page is gone.
    private func pruneStack() {
        let before = stack
        stack = CarPlayStack.kept(stack, template: { $0.template }, visible: ui.templates)
        for gone in before where !stack.contains(where: { $0.template === gone.template }) {
            sectionsCache.forget(ObjectIdentifier(gone.template))
            infoCache[ObjectIdentifier(gone.template)] = nil
        }
        if watchingDashcam, !stack.contains(where: { $0.screen == .dashcam }) {
            watchingDashcam = false
            sync.watchStatus(false)
        }
        if live != nil, !stack.contains(where: { $0.screen == .live }) { stopLive() }
    }

    // MARK: CPInterfaceControllerDelegate

    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated { cpDiag("didAppear \(type(of: aTemplate)) header=\(voiceTab.listHeader != nil)") }
    }

    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            cpDiag("didDisappear \(type(of: aTemplate))")
            // The voice screen went away without End/Done (the system took it): stop listening.
            if voice.owns(aTemplate) { voice.templateGone() }
            pruneStack()
        }
    }
}

/// TEMPORARY (2026-10-03): traces the voice card / header hand-off on the car; remove once settled.
func cpDiag(_ message: String) { print("[cp-diag] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)") }

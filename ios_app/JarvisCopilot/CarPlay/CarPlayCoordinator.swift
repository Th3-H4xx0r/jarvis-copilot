import CarPlay
import Combine
import Foundation
import Observation

/// Owns the car's screen: the Jarvis / Chats / Devices tabs, the screens pushed
/// over them (never deeper than three), and what every row does. State comes
/// from the same stores the phone uses; the screens themselves are the pure
/// builders in `CarPlayScreens`.
@available(iOS 26.4, *)
@MainActor
final class CarPlayCoordinator: NSObject, CPInterfaceControllerDelegate, CPTabBarTemplateDelegate {
    private let ui: CPInterfaceController
    private let jarvisTab = CPListTemplate(title: "Jarvis", sections: [])
    private let chatsTab = CPListTemplate(title: "Chats", sections: [])
    private let devicesTab = CPListTemplate(title: "Devices", sections: [])
    private var stack: [(screen: CarPlayScreen, template: CPTemplate)] = []
    private(set) lazy var voice = CarPlayVoiceScreen(ui: ui)

    /// The car's own library page (filter, paging), apart from the phone's.
    private let library = DashcamLibraryModel()
    private var sessions: [ChatSessionSummary] = []
    private var messages: [String: [ChatMessage]] = [:]
    private var serverDevices: [Device] = []
    private var drives: [DashcamDrive] = []
    private var cameraItems: [DashcamSettingItem] = []
    private var mic: DashcamMic?
    private var clipDetails: [String: (clip: DashcamServerClip, topMps: Double?)] = [:]
    private var reconnectNote: String?
    private var watchingDashcam = false
    private var refreshPending = false
    private var running = false
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
        jarvisTab.tabImage = UIImage(systemName: "atom")
        chatsTab.tabImage = UIImage(systemName: "bubble.left.and.bubble.right")
        devicesTab.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        let tabs = CPTabBarTemplate(templates: [jarvisTab, chatsTab, devicesTab])
        tabs.delegate = self
        ui.setRootTemplate(tabs, animated: false, completion: nil)
        refresh()
        observeStores()
        subscribeToDevices()
        Task {
            async let harnesses: Void = HarnessStore.shared.refresh()
            async let models: Void = VoiceModelStore.shared.load()
            _ = await (harnesses, models)
        }
        Task { await loadSessions() }
        Task { await loadServerDevices() }
    }

    func stop() {
        running = false
        cancellables.removeAll()
        if watchingDashcam { sync.watchStatus(false); watchingDashcam = false }
        voice.stop()
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
        jarvisTab.updateSections(render(paired ? CarPlayScreens.jarvisTab(voiceSummary) : CarPlayScreens.notPaired))
        chatsTab.updateSections(render(paired ? CarPlayScreens.chats(sessions) : CarPlayScreens.notPaired))
        devicesTab.updateSections(render(paired ? CarPlayScreens.devices(devicesInput) : CarPlayScreens.notPaired))
        for entry in stack { update(entry.template, for: entry.screen) }
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
            let h = HarnessStore.shared
            _ = h.assignments; _ = h.harnesses
            let m = VoiceModelStore.shared
            _ = m.selectedModelID; _ = m.catalog
            _ = VoiceSessionSelection.shared.target
            _ = JarvisPodStore.shared.rosterEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
                self?.observeStores()
            }
        }
    }

    /// `ObservableObject` stores: the dashcam, the car's library page, the wearables.
    private func subscribeToDevices() {
        let hub = WearablesHub.shared
        let feeds: [AnyPublisher<Void, Never>] = [
            sync.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            wifi.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            library.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hub.ring.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hub.x5.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hub.bottle.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hub.scale.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            hub.esp32.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
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

    private var voiceSummary: CarPlayVoiceSummary {
        let v = VoiceStore.shared
        let harnesses = HarnessStore.shared
        let current = harnesses.current(for: .voice, sessionHarnessID: nil)
        let state: String
        switch v.state {
        case .idle: state = v.error ?? "Tap to talk"
        case .error: state = v.error ?? "Something went wrong — tap to try again"
        case .connecting: state = "Connecting…"
        case .listening: state = "Listening…"
        case .thinking: state = "Thinking…"
        case .speaking: state = "Speaking"
        }
        return CarPlayVoiceSummary(stateText: state, chatLabel: VoiceSessionSelection.shared.chipLabel,
                                   harnessLabel: current == "single" ? "Single model" : harnesses.title(for: current),
                                   modelLabel: VoiceModelStore.shared.chipLabel)
    }

    private var wearables: [CarPlayWearable] {
        let hub = WearablesHub.shared
        return (hub.roster() + JarvisPodStore.shared.rosterEntries).map { e in
            var battery: Int?
            if e.connected, e.kind == WearableKeepAlive.ring { battery = hub.ring.session.battery?.percent }
            if e.connected, e.kind == WearableKeepAlive.x5ring { battery = hub.x5.session.battery?.percent }
            return CarPlayWearable(id: e.deviceID, kind: e.kind, name: e.name, model: e.model, statusText: e.statusText,
                                   connected: e.connected, batteryPercent: battery, lastSeen: e.lastSeen,
                                   rssi: e.rssi ?? e.lastRSSI)
        }
    }

    private var devicesInput: CarPlayDevicesInput {
        let setup = DashcamSetupStore.load()
        let status = [wifi.onCamera ? sync.phase.label : "Away",
                      wifi.onCamera && sync.recording == true ? "Recording" : nil,
                      sync.pendingUploads > 0 ? "\(sync.pendingUploads) to upload" : nil].compactMap { $0 }
        return CarPlayDevicesInput(
            dashcam: CarPlayDashcamRow(setUp: setup != nil, name: setup?.displayName ?? "Dashcam",
                                       status: status.joined(separator: " · ")),
            wearables: wearables, server: serverDevices)
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
            passActive: sync.passActive, mic: mic, canReconnect: DashcamSetupStore.password != nil,
            filter: library.filter, clips: library.clips, canLoadMore: library.canLoadMore,
            libraryError: library.error, pendingUploads: sync.pendingUploads)
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
        case .harnesses: return "Voice harness"
        case .modelProviders: return "Model"
        case .models(let provider): return provider
        case .voiceChats: return "Voice chat"
        case .chat(_, let title): return title
        case .message(let title, _): return title
        case .dashcam: return DashcamSetupStore.load()?.displayName ?? "Dashcam"
        case .clip: return "Clip"
        case .drives: return "Drives"
        case .dashcamSettings: return "Dashcam settings"
        case .device(let id): return wearables.first { $0.id == id }?.name ?? "Device"
        case .serverDevice(let id): return serverDevices.first { $0.id == id }?.displayName ?? "Device"
        }
    }

    private func sections(_ screen: CarPlayScreen) -> [CarPlaySection]? {
        switch screen {
        case .harnesses:
            let h = HarnessStore.shared
            return CarPlayScreens.harnesses(h.harnesses.map { ($0.id, $0.title) }, current: h.current(for: .voice, sessionHarnessID: nil))
        case .modelProviders:
            let m = VoiceModelStore.shared
            let providers = m.catalog?.providers ?? []
            return CarPlayScreens.modelProviders(providers, selectedProvider: m.selectedModel?.provider)
                + (m.loadError.map { [CarPlaySection(title: nil, rows: [CarPlayRow(id: "err", title: $0)])] } ?? [])
        case .models(let provider):
            let m = VoiceModelStore.shared
            return CarPlayScreens.models(m.catalog?.models(for: provider) ?? [], selectedID: m.selectedModelID)
        case .voiceChats:
            return CarPlayScreens.voiceChats(sessions, target: VoiceSessionSelection.shared.target)
        case .chat(let id, let title):
            guard let msgs = messages[id] else {
                return [CarPlaySection(title: nil, rows: [CarPlayRow(id: "loading", title: "Loading…")])]
            }
            return CarPlayScreens.chat(id: id, title: title, messages: msgs)
        case .dashcam: return CarPlayScreens.dashcam(dashcamInput)
        case .drives: return CarPlayScreens.drives(drives)
        case .dashcamSettings: return CarPlayScreens.dashcamSettings(settingsInput)
        case .message, .clip, .device, .serverDevice: return nil
        }
    }

    private func info(_ screen: CarPlayScreen) -> CarPlayInfo? {
        switch screen {
        case .message(let title, let text): return CarPlayScreens.message(title: title, text: text)
        case .clip(let id):
            guard let c = clip(id) else { return CarPlayInfo(title: "Clip", items: [CarPlayInfoItem(title: "Clip", detail: "Gone from the library")]) }
            return CarPlayScreens.clip(c, topMps: clipDetails[id]?.topMps)
        case .device(let id):
            guard let w = wearables.first(where: { $0.id == id }) else { return nil }
            return CarPlayScreens.device(w)
        case .serverDevice(let id):
            guard let d = serverDevices.first(where: { $0.id == id }) else { return nil }
            return CarPlayScreens.serverDevice(d)
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
        return list
    }

    private func update(_ template: CPTemplate, for screen: CarPlayScreen) {
        if let list = template as? CPListTemplate, let sections = sections(screen) {
            list.updateSections(render(sections))
        } else if let infoTemplate = template as? CPInformationTemplate, let info = info(screen) {
            CarPlayRenderer.update(infoTemplate, with: info) { [weak self] action in self?.handle(action) }
        }
    }

    private func push(_ screen: CarPlayScreen) {
        // Root is depth 1; the next push is always exactly one deeper, never past 3.
        guard screen.depth <= CarPlayScreen.maxDepth, screen.depth == stack.count + 2 else { return }
        let template = makeTemplate(screen)
        stack.append((screen, template))
        ui.pushTemplate(template, animated: true, completion: nil)
        load(screen)
    }

    /// What a screen fetches when it opens; the store observers refresh it after.
    private func load(_ screen: CarPlayScreen) {
        switch screen {
        case .harnesses: Task { await HarnessStore.shared.refresh() }
        case .modelProviders, .models: Task { await VoiceModelStore.shared.load() }
        case .voiceChats: Task { await loadSessions() }
        case .chat(let id, _):
            Task {
                messages[id] = (try? await SessionsAPI().get(id).messages) ?? []
                refresh()
            }
        case .dashcam:
            watchingDashcam = true
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
                drives = ((try? await DashcamAPI().drives()) ?? []).sorted { $0.start > $1.start }
                refresh()
            }
        case .dashcamSettings:
            Task {
                if !sync.rulesLoaded { await sync.refreshRules() }
                if wifi.onCamera { cameraItems = (try? await DashcamCameraSettings.load()) ?? [] }
                refresh()
            }
        case .message, .device, .serverDevice: break
        }
    }

    private func loadSessions() async {
        guard paired, let list = try? await SessionsAPI().list() else { return }
        sessions = list
        VoiceSessionSelection.shared.reconcile(with: list)
        refresh()
    }

    private func loadServerDevices() async {
        guard paired, let list = try? await DevicesAPI().list() else { return }
        serverDevices = list
        refresh()
    }

    // MARK: Actions

    func handle(_ action: CarPlayAction) {
        switch action {
        case .none: break
        case .push(let screen): push(screen)
        case .startVoice: voice.start()
        case .selectHarness(let id):
            Task { await HarnessStore.shared.assign(id, to: .voice) }
            ui.popToRootTemplate(animated: true, completion: nil)
        case .selectModel(let id, _):
            // As on the phone, a picked model means Voice runs "Single model".
            let store = VoiceModelStore.shared
            store.select(id.flatMap { id in store.catalog?.models.first { $0.id == id } })
            Task { await HarnessStore.shared.assign("single", to: .voice) }
            ui.popToRootTemplate(animated: true, completion: nil)
        case .selectVoiceChat(let id, let title):
            VoiceSessionSelection.shared.select(id.map { .session(id: $0, title: title) } ?? .defaultVoice)
            VoiceStore.shared.sessionTargetChanged()
            ui.popTemplate(animated: true, completion: nil)
        case .newVoiceChat:
            Task {
                do {
                    try await VoiceSessionSelection.shared.startNewSession()
                    VoiceStore.shared.sessionTargetChanged()
                } catch { alert(apiErrorMessage(error)) }
            }
            ui.popTemplate(animated: true, completion: nil)
        case .continueByVoice(let id, let title):
            VoiceSessionSelection.shared.select(.session(id: id, title: title))
            VoiceStore.shared.sessionTargetChanged()
            voice.start()
        case .dashcam(let command): run(command)
        case .clip(let id, let command): run(command, clipID: id)
        case .connectWearable(let id):
            Task {
                let ok = await WearablesHub.shared.connect(deviceID: id)
                alert(ok ? "Connected." : "Couldn't reach it — is it nearby and awake?")
            }
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
                    self.ui.popTemplate(animated: true, completion: nil)
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

    // MARK: CPInterfaceControllerDelegate

    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            // A screen popped off the stack (Back): forget it, and stop polling the camera with the dashcam page.
            guard let index = stack.firstIndex(where: { $0.template === aTemplate }),
                  !ui.templates.contains(where: { $0 === aTemplate }) else { return }
            stack.removeSubrange(index...)
            if watchingDashcam, !stack.contains(where: { $0.screen == .dashcam }) {
                watchingDashcam = false
                sync.watchStatus(false)
            }
        }
    }

    // MARK: CPTabBarTemplateDelegate

    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        MainActor.assumeIsolated {
            if selectedTemplate === chatsTab { Task { await loadSessions() } }
            if selectedTemplate === devicesTab { Task { await loadServerDevices() } }
        }
    }
}

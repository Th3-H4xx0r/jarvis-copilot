import XCTest
@testable import JarvisCopilot

/// The PC in Agents (Windows client, 2026-11-15): the same card as the Mac, told apart by
/// `os`, with Wake PC / Sleep / Lock / Unlock; its live view's Command Center shows
/// only what Windows has; a share asks for the PC by its device id.
@MainActor
final class AgentsPcPowerCardTests: XCTestCase {

    private func row(_ json: [String: Any]) -> AgentMacPower {
        AgentMacPower(json: ["device_id": "pc-1", "name": "Pranav-Desktop", "state": "awake"].merging(json) { $1 })
    }

    func testPcRowDecodesOsAndWake() {
        let pc = row(["os": "windows", "wake_capable": false, "wake_reason": "this Wi-Fi adapter can't wake the PC"])
        XCTAssertTrue(pc.isPC)
        XCTAssertEqual(pc.wakeCapable, false)
        XCTAssertEqual(pc.wakeReason, "this Wi-Fi adapter can't wake the PC")
    }

    func testOldRowDefaultsToMac() {
        let mac = AgentMacPower(json: ["device_id": "mac-1", "name": "MacBook", "state": "awake"])
        XCTAssertEqual(mac.os, "macos")
        XCTAssertFalse(mac.isPC)
        XCTAssertNil(mac.wakeCapable)
    }

    func testWakeTitleByOs() {
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "windows"), "Wake PC")
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "macos"), "Wake Mac")
    }

    func testPcActionsOfferLockAndUnlock() {
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "windows"])), [.letSleep, .lock, .unlock])
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "macos"])), [.letSleep, .unlock])
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "windows", "state": "sleeping"])), [.wake])
    }

    func testAPcWakeWaitsTwoMinutesAndMentionsTheSignInScreen() {
        // Live: a failed / slow PC wake showed "Waking… up to 15 min from deep sleep" for 20 minutes.
        let asked = Date(timeIntervalSince1970: 1_000)
        let pc = row(["os": "windows", "state": "sleeping", "wake_requested_at": 1_000])
        XCTAssertEqual(AgentsMacPowerCopy.status(pc, now: asked.addingTimeInterval(30)).label, "Waking…")
        XCTAssertEqual(AgentsMacPowerCopy.status(pc, now: asked.addingTimeInterval(90)).detail,
                       "It may be at the sign-in screen")
        XCTAssertNotEqual(AgentsMacPowerCopy.status(pc, now: asked.addingTimeInterval(150)).label, "Waking…")
        let mac = row(["os": "macos", "state": "sleeping", "wake_requested_at": 1_000])
        XCTAssertEqual(AgentsMacPowerCopy.status(mac, now: asked.addingTimeInterval(150)).label, "Waking…")
    }

    func testThePcIsCalledAPcNotAMac() {
        // An offline PC used to arrive named "Mac" (the server's generic fallback).
        XCTAssertEqual(AgentsMacPowerCopy.cardName("Mac", os: "windows"), "Your PC")
        XCTAssertEqual(AgentsMacPowerCopy.noun(isPC: true), "PC")
        XCTAssertEqual(AgentsMacPowerCopy.noun(isPC: false), "Mac")
        let pc = AgentConv(json: ["ckey": "claude|p", "agent": "claude", "owner": "pc-1", "owner_os": "windows",
                                  "status": "asleep"])
        XCTAssertEqual(AgentsListLayout.statusLabel(pc, request: nil), "PC asleep")
        XCTAssertEqual(AgentsListLayout.whereLabel(pc), "PC (asleep)")
        let mac = AgentConv(json: ["ckey": "claude|m", "agent": "claude", "owner": "mac-1", "status": "offline"])
        XCTAssertEqual(AgentsListLayout.statusLabel(mac, request: nil), "Mac offline")
        XCTAssertEqual(MacAppSwitcherContent.connecting.message(computer: "PC"), "Connecting to your PC…")
        XCTAssertEqual(MacAppSwitcherContent.connecting.message, "Connecting to your Mac…")
        let unlock = MacPasswordRequest(json: ["id": "r", "device_id": "pc", "kind": "unlock", "context": "Unlock PC",
                                               "nonce": "n", "expires": 0])
        XCTAssertTrue(MacPasswordSheetCopy.isPC(unlock))
        XCTAssertFalse(MacPasswordSheetCopy.showsRequest(kind: "unlock", context: "Unlock PC"))
    }

    func testPcNameKeptAsWindowsHasIt() {
        XCTAssertEqual(AgentsMacPowerCopy.cardName("Pranav-Desktop", os: "windows"), "Pranav-Desktop")
        XCTAssertEqual(AgentsMacPowerCopy.cardName("", os: "windows"), "Your PC")
        XCTAssertEqual(AgentsMacPowerCopy.cardName("Pranavs-MacBook-Pro.local", os: "macos"), "Pranav's MacBook Pro")
    }

    func testWakeLine() {
        XCTAssertEqual(AgentsMacPowerCopy.wakeLine(row(["os": "windows", "wake_capable": true])),
                       "Wakes over Wi-Fi from your other computer")
        XCTAssertEqual(AgentsMacPowerCopy.wakeLine(row(["os": "windows", "wake_capable": false])),
                       "This PC's Wi-Fi adapter can't be woken remotely")
    }

    func testLockActionPath() {
        XCTAssertEqual(AgentsStore.MacPowerAction.lock.path, "lock")
    }

    func testCommandCenterShowsOnlyWindowsSwitchesForPc() {
        XCTAssertEqual(MacControlItem.switchItems(isPC: true), [.wifi, .bluetooth, .dark])
        XCTAssertFalse(MacControlItem.switchItems(isPC: true).contains(.stage))
        XCTAssertTrue(MacControlItem.switchItems(isPC: false).contains(.stage))
        XCTAssertEqual(MacControlItem.powerButtons(isPC: true), [.lock, .sleep])
        XCTAssertEqual(MacControlItem.powerButtons(isPC: false), [.unlock, .lock, .sleep])
    }

    func testShareAsksForItsComputer() {
        XCTAssertEqual(MacScreenSession.shareRequest(deviceId: "pc-1")["device_id"] as? String, "pc-1")
        XCTAssertEqual(MacScreenSession.shareRequest(deviceId: "pc-1")["reason"] as? String, "anytime")
        XCTAssertNil(MacScreenSession.shareRequest(deviceId: nil)["device_id"])
    }

    func testAdminApprovalTitleInTheAppsWords() {
        XCTAssertEqual(PcAdminCopy.title(source: "Pranav-Desktop"), "Run as admin on Pranav-Desktop")
        XCTAssertEqual(PcAdminCopy.title(source: ""), "Run as admin on your PC")
    }

    // jc-client up, the Jarvis app gone (live 2026-11-18: the card said Awake, Screen and Remote Desktop said offline).
    func testAppDownIsSaidPlainly() {
        XCTAssertEqual(row(["os": "windows", "app_running": false]).appRunning, false)
        XCTAssertNil(row(["os": "windows"]).appRunning)
        XCTAssertEqual(AgentsMacPowerCopy.appDownLine, "The Jarvis app isn't running on this PC · open it there")
        let seen = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PcStatsCopy.status(online: false, at: seen, appDown: true, now: seen.addingTimeInterval(44 * 60)),
                       "Jarvis app not running · last seen 44 min ago")
    }

    // MARK: the PC power button (2026-11-23): an ESP32 on the front-panel header

    private func pc(_ state: String = "sleeping", linked: Bool = true, connected: Bool = true,
                    light: String = "asleep", _ extra: [String: Any] = [:]) -> AgentMacPower {
        row(["os": "windows", "state": state,
             "power_button": ["linked": linked, "connected": connected, "name": "PC Button", "light": light]]
            .merging(extra) { $1 })
    }

    private func approval(_ command: String) -> FaceIDApproval {
        FaceIDApproval(json: ["id": "ap-1", "command": command])!
    }

    func testDecodesPowerButton() throws {
        let off = pc("off", light: "off")
        let button = try XCTUnwrap(off.powerButton)
        XCTAssertTrue(button.linked)
        XCTAssertTrue(button.connected)
        XCTAssertEqual(button.name, "PC Button")
        XCTAssertEqual(button.light, "off")
        XCTAssertEqual(off.state, .off)
        XCTAssertTrue(off.isOff)
        XCTAssertFalse(off.isAwake)
        XCTAssertNil(row(["os": "windows"]).powerButton, "a server without the board sends none")
        XCTAssertFalse(row(["os": "windows", "state": "sleeping"]).isOff)
    }

    func testOffStatus() {
        let seen = Date(timeIntervalSince1970: 1_000)
        let off = pc("off", light: "off", ["seen_at": 1_000])
        let status = AgentsMacPowerCopy.status(off, now: seen.addingTimeInterval(600))
        XCTAssertEqual(status.tone, .off)
        XCTAssertEqual(status.label, "Off")
        XCTAssertEqual(status.detail, "last seen 10 min ago")
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: off), [.wake])
        // Turning it on reads like a wake until it answers.
        let asked = pc("off", light: "off", ["wake_requested_at": 1_000])
        XCTAssertEqual(AgentsMacPowerCopy.status(asked, now: seen.addingTimeInterval(10)).label, "Waking…")
    }

    func testTurnOnTitleWhenOff() {
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "windows", off: true), "Turn on PC")
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "windows", off: false), "Wake PC")
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "windows"), "Wake PC")
    }

    func testPowerButtonLine() {
        XCTAssertEqual(AgentsMacPowerCopy.powerButtonLine(pc()), "Connected")
        XCTAssertEqual(AgentsMacPowerCopy.powerButtonLine(pc(connected: false)), "Offline · using Wi-Fi wake")
        XCTAssertNil(AgentsMacPowerCopy.powerButtonLine(pc(linked: false)), "two boards / no link: no line")
        XCTAssertNil(AgentsMacPowerCopy.powerButtonLine(row(["os": "windows"])))
    }

    func testForceActionsOnlyWithLinkedBoard() {
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: pc("awake", light: "on")),
                       [.restart, .shutdown, .forceRestart, .forceOff])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: row(["os": "windows"])), [.restart, .shutdown])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: pc("awake", linked: false)), [.restart, .shutdown])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: pc("awake", connected: false)), [.restart, .shutdown],
                       "an offline board can't press anything")
        // Asleep, off or frozen: only the button reaches it.
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: pc("sleeping")), [.forceRestart, .forceOff])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: pc("off", light: "off")), [.forceRestart, .forceOff])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: row(["os": "windows", "state": "sleeping"])), [])
        XCTAssertEqual(AgentsMacPowerCopy.powerMenu(for: row(["os": "macos"])), [], "the Mac is unchanged")
    }

    func testTheButtonWakesAPcItsWiFiCantWake() {
        XCTAssertFalse(AgentsMacPowerCopy.canWake(row(["os": "windows", "state": "sleeping", "wake_capable": false])))
        XCTAssertTrue(AgentsMacPowerCopy.canWake(pc("sleeping", ["wake_capable": false])))
        XCTAssertFalse(AgentsMacPowerCopy.canWake(pc("sleeping", connected: false, ["wake_capable": false])))
        XCTAssertTrue(AgentsMacPowerCopy.canWake(row(["os": "macos", "state": "sleeping"])))
    }

    func testAPcStartingUpSaysJarvisIsNotConnectedYet() {
        XCTAssertEqual(AgentsMacPowerCopy.reason("starting"), "Jarvis isn't connected yet")
        // Right after a wake it stays "Waking…" until jc-client reports, so Sleep isn't the next tap.
        let asked = Date(timeIntervalSince1970: 1_000)
        let booting = pc("awake", light: "on", ["reason": "starting", "wake_requested_at": 1_000])
        XCTAssertEqual(AgentsMacPowerCopy.status(booting, now: asked.addingTimeInterval(10)).label, "Waking…")
        XCTAssertEqual(AgentsMacPowerCopy.status(booting, now: asked.addingTimeInterval(300)).label, "Awake")
        XCTAssertEqual(AgentsMacPowerCopy.status(booting, now: asked.addingTimeInterval(300)).detail,
                       "Jarvis isn't connected yet")
    }

    func testPowerActionPaths() {
        XCTAssertEqual(AgentsStore.MacPowerAction.restart.path, "restart")
        XCTAssertEqual(AgentsStore.MacPowerAction.shutdown.path, "shutdown")
        XCTAssertEqual(AgentsStore.MacPowerAction.forceRestart.path, "force_restart")
        XCTAssertEqual(AgentsStore.MacPowerAction.forceOff.path, "force_off")
        XCTAssertTrue(AgentsStore.MacPowerAction.forceOff.isForce)
        XCTAssertFalse(AgentsStore.MacPowerAction.restart.isForce)
    }

    func testPcForcePostsTheActionAndReadsTheApproval() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/pc-power/force", json: ["approval": [
            "id": "ap-1", "command": "force_off", "title": "Force off PC", "source": "iPhone",
            "age_s": 0, "expires_in_s": 120]])
        let approval = try await AgentsAPI(api: api).pcForce(action: "force_off", deviceId: "pc-1")
        XCTAssertEqual(approval.id, "ap-1")
        XCTAssertEqual(approval.command, "force_off")
        XCTAssertEqual(approval.expiresInSeconds, 120)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/pc-power/force")
        XCTAssertEqual(transport.lastBody()["device_id"] as? String, "pc-1")
        XCTAssertEqual(transport.lastBody()["action"] as? String, "force_off")
    }

    func testPcPowerApprovalInTheAppsWords() {
        let domain = PcPowerApprovalDomain()
        XCTAssertEqual(domain.prefix, "/api/pc-power")
        XCTAssertEqual(domain.signingDomain, "jarvis-pc-power")
        XCTAssertEqual(domain.title(for: approval("force_restart")), "Force restart your PC")
        XCTAssertEqual(domain.title(for: approval("force_off")), "Force off your PC")
        XCTAssertNil(domain.title(for: approval("run-as-admin")), "never approves what it doesn't know")
        XCTAssertTrue(FaceIDApprovals.pcPower.domain is PcPowerApprovalDomain)
    }

    func testForceAnswerReadsTheServer() {
        let held = PcPowerCopy.answer(command: "force_off", reply: ["ok": true, "result": ["ok": true]])
        XCTAssertTrue(held.ok)
        XCTAssertEqual(held.text, "Holding the power button for 6 seconds")
        let busy = PcPowerCopy.answer(command: "force_restart",
                                      reply: ["ok": true, "result": ["ok": false, "error": "busy"]])
        XCTAssertFalse(busy.ok)
        XCTAssertEqual(busy.text, "busy")
        let refused = PcPowerCopy.answer(command: "force_off",
                                         reply: ["ok": false, "error": "No power button is linked to this PC."])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.text, "No power button is linked to this PC.")
    }
}

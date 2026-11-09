import XCTest
@testable import JarvisCopilot

/// "I meant buttons from the control center menu": the live view pins the Command Center's own
/// items (Wi-Fi, Now Playing, Sound, Lock…), and a pinned item does exactly what its tile in the
/// Command Center sheet does — one item model, one action path.
@MainActor
final class MacControlItemsTests: XCTestCase {
    private func state(_ json: [String: Any]) -> MacControlState { MacControlState(json: json) }

    private func freshDefaults() -> UserDefaults {
        let name = "MacControlItemsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: the items

    func testEveryCommandCenterItemHasANameAndSymbolAndAStableId() {
        let ids = MacControlItem.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        for item in MacControlItem.allCases {
            XCTAssertFalse(item.title.isEmpty, "\(item)")
            XCTAssertFalse(item.symbol.isEmpty, "\(item)")
            XCTAssertEqual(MacControlItem(rawValue: item.rawValue), item)
        }
        // The sheet's sections are made of the same items.
        let sections = MacControlItem.switches + MacControlItem.mediaAndSliders + MacControlItem.power + MacControlItem.shortcuts
        XCTAssertEqual(Set(sections), Set(MacControlItem.allCases))
    }

    func testEveryShortcutOfTheSheetIsAnItem() {
        for s in MacShortcut.all {
            XCTAssertTrue(MacControlItem.shortcuts.contains { $0.shortcut?.title == s.title }, s.title)
        }
    }

    func testTogglesShowTheMacsStateAndFlipIt() {
        let c = state(["wifi": true, "wifi_name": "Home", "bluetooth": false, "dark": true])
        XCTAssertEqual(MacControlItem.wifi.face(c).subtitle, "Home")
        XCTAssertTrue(MacControlItem.wifi.face(c).on)
        XCTAssertEqual(MacControlItem.wifi.tap(c), .toggle("wifi", on: false))
        XCTAssertEqual(MacControlItem.bluetooth.face(c).subtitle, "Off")
        XCTAssertEqual(MacControlItem.bluetooth.tap(c), .toggle("bluetooth", on: true))
        XCTAssertEqual(MacControlItem.dark.tap(c), .toggle("dark", on: false))
        // Before the Mac said: a dash, and a tap switches it on.
        let unknown = MacControlState()
        XCTAssertEqual(MacControlItem.wifi.face(unknown).subtitle, "—")
        XCTAssertFalse(MacControlItem.wifi.face(unknown).on)
        XCTAssertEqual(MacControlItem.wifi.tap(unknown), .toggle("wifi", on: true))
    }

    func testSwitchesMacOSWontLetAnAppFlipOpenTheMacsControlCenter() {
        let c = state(["stage": true])
        for item in [MacControlItem.stage, .airdrop, .focus, .mirroring, .controlCenter] {
            XCTAssertEqual(item.tap(c), .command("control_center"), "\(item)")
            XCTAssertTrue(item.opensMacControlCenter)
        }
        XCTAssertTrue(MacControlItem.stage.face(c).on)
        XCTAssertEqual(MacControlItem.airdrop.face(c).subtitle, "On the Mac")
    }

    func testSlidersAndNowPlayingShowTheirValues() {
        let c = state(["volume": 40, "muted": false, "brightness": 0.6,
                       "now": ["title": "Midnight City", "artist": "M83", "playing": true]])
        XCTAssertEqual(MacControlItem.sound.face(c).subtitle, "40%")
        XCTAssertEqual(MacControlItem.display.face(c).subtitle, "60%")
        XCTAssertEqual(MacControlItem.nowPlaying.face(c).title, "Midnight City")
        XCTAssertEqual(MacControlItem.nowPlaying.face(c).subtitle, "M83")
        XCTAssertNil(MacControlItem.sound.tap(c), "a slider has its own control, never a plain tap")
        XCTAssertNil(MacControlItem.nowPlaying.tap(c))
        let muted = state(["volume": 40, "muted": true])
        XCTAssertEqual(MacControlItem.sound.face(muted).subtitle, "Muted")
        XCTAssertEqual(MacControlItem.sound.face(muted).symbol, "speaker.slash.fill")
        // An external display has no brightness: the item says so and does nothing.
        XCTAssertFalse(MacControlItem.display.isAvailable(MacControlState(), hasMac: true))
        XCTAssertTrue(MacControlItem.display.isAvailable(c, hasMac: true))
    }

    func testPowerGoesThroughTheSameRulesAsTheSheet() {
        let locked = state(["locked": true])
        XCTAssertEqual(MacControlItem.unlock.tap(locked), .unlock)
        XCTAssertEqual(MacControlItem.unlock.face(locked).subtitle, "Locked")
        XCTAssertTrue(MacControlItem.unlock.face(locked).on)
        XCTAssertEqual(MacControlItem.lock.tap(locked), .lock)
        XCTAssertEqual(MacControlItem.sleep.tap(locked), .sleep)
        XCTAssertEqual(MacControlItem.keepAwake.tap(locked, keepAwake: true), .keepAwake(false))
        XCTAssertEqual(MacControlItem.keepAwake.tap(locked, keepAwake: false), .keepAwake(true))
        XCTAssertTrue(MacControlItem.keepAwake.face(locked, keepAwake: true).on)
        XCTAssertFalse(MacControlItem.keepAwake.isAvailable(locked, hasMac: false), "no Mac on the server")
    }

    func testShortcutsSendTheirKeysAndSwitchAppOpensThePhonesList() {
        let c = MacControlState()
        XCTAssertEqual(MacControlItem.spotlight.tap(c), .key("space", mods: ["cmd"]))
        XCTAssertEqual(MacControlItem.screenshot.tap(c), .key("5", mods: ["cmd", "shift"]))
        XCTAssertEqual(MacControlItem.switchApp.tap(c), .appSwitcher)
        XCTAssertEqual(MacControlItem.missionControl.tap(c), .command("mission_control"))
        XCTAssertEqual(MacControlItem.showDesktop.tap(c), .command("show_desktop"))
    }

    func testATapGoesOverTheChannelWithTheSheetsOptimisticChange() {
        let session = MacScreenSession(shareID: "t")
        session.receivedForTesting(["t": "cc_state", "wifi": false, "dark": false])
        let actions = session.controlActions
        actions.perform(.wifi)
        XCTAssertEqual(session.controls.wifi, true, "the tile flips at once")
        actions.perform(.lock)
        XCTAssertEqual(session.controls.locked, true)
        actions.media("play")
        XCTAssertEqual(session.controls.nowPlaying, true)
        actions.perform(.switchApp)
        XCTAssertTrue(actions.wantsSwitcher)
    }

    func testTheSlidersFollowTheMacUntilHeDrags() {
        let session = MacScreenSession(shareID: "t")
        session.receivedForTesting(["t": "cc_state", "volume": 30, "brightness": 0.2])
        XCTAssertEqual(session.controlActions.volume, 30)
        XCTAssertEqual(session.controlActions.brightness, 0.2)
        session.receivedForTesting(["t": "cc_state", "volume": 55])
        XCTAssertEqual(session.controlActions.volume, 55)
    }

    // MARK: pins

    func testDefaultPinsAreNowPlayingAndSound() {
        let pins = MacControlPins.load(defaults: freshDefaults())
        XCTAssertEqual(pins.visible, [.nowPlaying, .sound])
        XCTAssertEqual(pins.rows.count, MacControlItem.allCases.count)
    }

    func testPinnedItemsShowInHisOrder() {
        var pins = MacControlPins(pinned: [])
        XCTAssertTrue(pins.visible.isEmpty)
        pins.set(.lock, on: true)
        pins.set(.wifi, on: true)
        XCTAssertEqual(pins.visible, [.wifi, .lock], "unarranged items keep the sheet's order")
        let rows = pins.rows.map(\.rawValue)
        let lockAt = rows.firstIndex(of: "lock")!
        pins.move(in: rows, from: IndexSet(integer: lockAt), to: 0)
        XCTAssertEqual(pins.rows.first, .lock)
        XCTAssertEqual(pins.visible, [.lock, .wifi])
        pins.set(.lock, on: false)
        XCTAssertEqual(pins.visible, [.wifi])
        XCTAssertFalse(pins.isPinned(.lock))
        XCTAssertEqual(pins.rows.first, .lock, "an unpinned row keeps its place")
    }

    func testPinsSurviveARestartAndUnknownIdsAreDroppedQuietly() {
        let defaults = freshDefaults()
        var pins = MacControlPins(pinned: [])
        pins.set(.bluetooth, on: true)
        pins.set(.sleep, on: true)
        pins.save(defaults: defaults)
        XCTAssertEqual(MacControlPins.load(defaults: defaults).visible, [.bluetooth, .sleep])

        // A build that knew an item this one doesn't (or a typo): it disappears, nothing else changes.
        let stored = #"{"order":["teleport","sleep","bluetooth"],"pinned":["teleport","sleep","bluetooth"]}"#
        let storedData: Data = stored.data(using: .utf8)!
        defaults.setValue(storedData, forKey: MacControlPins.key)
        let loaded = MacControlPins.load(defaults: defaults)
        XCTAssertEqual(loaded.visible, [.sleep, .bluetooth])
        XCTAssertFalse(loaded.order.contains("teleport"))
        XCTAssertFalse(loaded.pinned.contains("teleport"))

        // Everything switched off stays off (never back to the defaults).
        MacControlPins(pinned: []).save(defaults: defaults)
        XCTAssertTrue(MacControlPins.load(defaults: defaults).visible.isEmpty)
    }

    func testTheModelSavesEveryChangeAndForgetsTheOldButtonsRow() {
        let defaults = freshDefaults()
        let old: Data = "{}".data(using: .utf8)!
        defaults.setValue(old, forKey: "jc.macScreen.buttons")
        let model = MacControlPinsModel(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "jc.macScreen.buttons"), "e966a60fa5's selection is gone")
        model.update { $0.set(.dark, on: true) }
        // A newly pinned item takes its row's place (the editor's order), here before Now Playing.
        XCTAssertEqual(MacControlPinsModel(defaults: defaults).pins.visible, [.dark, .nowPlaying, .sound])
    }
}

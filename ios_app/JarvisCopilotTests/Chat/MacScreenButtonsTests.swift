import SwiftUI
import XCTest
@testable import JarvisCopilot

/// "I want the live view page to be customizable so that I can add whatever buttons I want
/// from the control center to show up on that page as I please."
@MainActor
final class MacScreenButtonsTests: XCTestCase {
    private func button(_ id: String) -> ControlButton {
        ControlButton(id: id, name: id.capitalized, symbol: "bolt.fill", action: .prompt("hi", agent: nil))
    }

    private var shelf: [ControlButton] { ["lights", "door", "car", "music"].map(button) }

    private func freshDefaults() -> UserDefaults {
        let name = "MacScreenButtonsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testNothingShowsUntilHeChoosesButtons() {
        let selection = MacScreenButtonSelection()
        XCTAssertTrue(selection.visible(shelf).isEmpty)
        XCTAssertEqual(selection.rows(shelf).map(\.id), ["lights", "door", "car", "music"])
    }

    func testChosenButtonsShowInHisOrder() {
        var selection = MacScreenButtonSelection()
        selection.set("car", on: true)
        selection.set("lights", on: true)
        XCTAssertEqual(selection.visible(shelf).map(\.id), ["lights", "car"])
        // Drag Car above Lights in the editor.
        selection.move(in: selection.rows(shelf).map(\.id), from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(selection.rows(shelf).map(\.id), ["car", "lights", "door", "music"])
        XCTAssertEqual(selection.visible(shelf).map(\.id), ["car", "lights"])
        selection.set("car", on: false)
        XCTAssertEqual(selection.visible(shelf).map(\.id), ["lights"])
        XCTAssertFalse(selection.isChosen("car"))
    }

    func testAButtonDeletedFromControlCenterQuietlyDisappears() {
        var selection = MacScreenButtonSelection()
        selection.set("door", on: true)
        selection.set("music", on: true)
        let afterDelete = shelf.filter { $0.id != "door" }
        XCTAssertEqual(selection.visible(afterDelete).map(\.id), ["music"])
        XCTAssertTrue(selection.pruned(to: afterDelete))
        XCTAssertFalse(selection.isChosen("door"))
        XCTAssertFalse(selection.pruned(to: afterDelete), "nothing left to prune")
        // A new button made later with no place yet goes last, off.
        let withNew = afterDelete + [button("fan")]
        XCTAssertEqual(selection.rows(withNew).last?.id, "fan")
        XCTAssertFalse(selection.isChosen("fan"))
    }

    func testTheSelectionSurvivesARestart() {
        let defaults = freshDefaults()
        var selection = MacScreenButtonSelection.load(defaults: defaults)
        XCTAssertEqual(selection, MacScreenButtonSelection())
        selection.set("music", on: true)
        selection.set("door", on: true)
        selection.move(in: selection.rows(shelf).map(\.id), from: IndexSet(integer: 3), to: 0)
        selection.save(defaults: defaults)
        let reloaded = MacScreenButtonSelection.load(defaults: defaults)
        XCTAssertEqual(reloaded, selection)
        XCTAssertEqual(reloaded.visible(shelf).map(\.id), ["music", "door"])
    }

    func testATapRunsWhatControlCenterRunsButNeverSkipsFaceID() {
        var door = button("door")
        door.action = .door(.disarm, skipFaceID: true)
        door.timeline = ButtonTimeline(ButtonLiveState(id: "door.armed", title: "Disarm", symbol: "lock.open"))
        let press = MacScreenButtonRow.press(for: door, at: .now)
        XCTAssertEqual(press.buttonID, "door")
        XCTAssertFalse(press.physical, "the skip-Face-ID button key is only for his own Control Center press")
        XCTAssertNil(press.widgetID)
        XCTAssertEqual(press.shownState, "door.armed", "a live button runs what its tile shows now")
        XCTAssertNil(MacScreenButtonRow.press(for: button("lights"), at: .now).shownState)
    }

    func testTheTileShowsTheLiveStateLikeControlCenter() {
        var car = button("car")
        XCTAssertEqual(MacScreenButtonRow.face(for: car, at: .now).title, "Car")
        car.timeline = ButtonTimeline(ButtonLiveState(id: "car.locked", title: "Unlock", symbol: "lock.open.fill"))
        let face = MacScreenButtonRow.face(for: car, at: .now)
        XCTAssertEqual(face.title, "Unlock")
        XCTAssertEqual(face.symbol, "lock.open.fill")
    }

    func testATapRunsTheButtonsActionWithoutTheSkipPath() async {
        let defaults = freshDefaults()
        var contexts: [RingActionContext] = []
        var ran: [RingAction] = []
        let store = ControlButtonStore(defaults: defaults, reloadControls: {},
                                       runAction: { action, context in
                                           ran.append(action)
                                           contexts.append(context)
                                           return "done"
                                       },
                                       notify: { _, _ in }, keepAliveIsOn: { _ in false }, widgetAgent: { _ in nil })
        store.resolvePress = { button, _ in .run(button.action) }
        store.didRun = { _, _, _ in }
        store.restate = {}
        var door = button("alarm")  // not "door": that id is the server door card's
        door.action = .door(.disarm, skipFaceID: true)
        store.save(door)
        await store.run(MacScreenButtonRow.press(for: door, at: .now))
        XCTAssertEqual(ran, [.door(.disarm, skipFaceID: true)])
        XCTAssertEqual(contexts.first?.physical, false, "Face ID path, never the button key")
        XCTAssertEqual(contexts.first?.chatKey, "button.alarm", "same chat as the Control Center press")
    }

    // MARK: renders (to /tmp/ringshots)

    private func renderRig() -> (ControlButtonStore, MacScreenButtonsModel) {
        let defaults = freshDefaults()
        let store = ControlButtonStore(defaults: defaults, reloadControls: {}, runAction: { _, _ in "done" },
                                       notify: { _, _ in }, keepAliveIsOn: { _ in false }, widgetAgent: { _ in nil })
        store.restate = {}
        for (id, name, symbol) in [("lights", "Desk lights", "lightbulb.fill"), ("door", "Door alarm", "lock.shield"),
                                   ("car", "Start car", "car.fill"), ("music", "Focus music", "music.note"),
                                   ("fan", "Fan", "fan.fill")] {
            store.save(ControlButton(id: id, name: name, symbol: symbol, action: .prompt("hi", agent: nil)))
        }
        let model = MacScreenButtonsModel(defaults: defaults)
        model.update {
            $0.set("lights", on: true)
            $0.set("door", on: true)
            $0.set("car", on: true)
        }
        return (store, model)
    }

    func testRenderLiveViewButtons() throws {
        let (store, model) = renderRig()
        let session = MacScreenSession(shareID: "preview")
        session.receivedForTesting(["t": "cc_apps", "apps": [
            ["pid": 1, "name": "Finder", "bundle": "a", "active": false],
            ["pid": 2, "name": "Brave Browser", "bundle": "b", "active": true],
            ["pid": 3, "name": "Messages", "bundle": "d", "active": false],
        ]])
        let portrait = VStack(spacing: 0) {
            ZStack {
                Color(white: 0.12)
                Text("Mac screen").font(.footnote).foregroundStyle(JcTheme.muted)
            }
            MacScreenButtonRow(store: store, model: model).background(Color.black)
            MacAppStrip(session: session).background(Color.black)
        }
        .background(Color.black)
        try RenderHarness.write(portrait, size: CGSize(width: 402, height: 420), name: "mac-live-buttons")
        try RenderHarness.write(MacScreenButtonsEditor(store: store, model: model),
                                size: CGSize(width: 402, height: 640), name: "mac-live-buttons-editor")
        let empty = MacScreenButtonsModel(defaults: freshDefaults())
        try RenderHarness.write(MacScreenButtonRow(store: store, model: empty).background(Color.black),
                                size: CGSize(width: 402, height: 60), name: "mac-live-buttons-empty")
    }
}

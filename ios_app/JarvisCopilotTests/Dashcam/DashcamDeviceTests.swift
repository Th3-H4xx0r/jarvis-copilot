import XCTest
@testable import JarvisCopilot

@MainActor
final class DashcamDeviceTests: XCTestCase {
    private var device: DashcamDevice!
    private var cam: FakeDashcam!
    private var onCamera = true

    override func setUp() async throws {
        cam = FakeDashcam()
        onCamera = true
        device = DashcamDevice()
        let sync = DashcamSync()
        sync.cameraFactory = { [unowned self] _ in self.cam }
        sync.setupProvider = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM") }
        sync.onCameraProvider = { [unowned self] in self.onCamera }
        device.sync = sync
        device.wifi = { [unowned self] in self.onCamera }
        device.setup = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM", brand: "Affver", lenses: 2) }
    }

    func testOffersTheSkillsTheServerSkillCalls() {
        let names = Set(device.capabilities.map(\.name))
        XCTAssertEqual(names, ["dashcam_get_status", "dashcam_sync", "dashcam_lock_clip", "dashcam_snapshot",
                               "dashcam_set_recording", "dashcam_get_settings", "dashcam_set_setting", "dashcam_sd_info",
                               "dashcam_format_sd", "dashcam_delete_file", "dashcam_set_wifi", "dashcam_fetch_range",
                               "dashcam_set_options", "dashcam_sync_clock"])
        XCTAssertEqual(device.deviceID, "dashcam-CAM")
    }

    func testDeleteFileToolQueuesWhenAway() async throws {
        onCamera = false
        let server = FakeSyncServer()
        device.sync.server = server
        device.sync.defaults = UserDefaults(suiteName: "dashcam-device-\(UUID().uuidString)")!
        let out = try await device.invoke("dashcam_delete_file", args: ["path": "/mnt/card/video_front/a_f.ts", "confirm": true])
        XCTAssertEqual(out["queued"] as? Bool, true)
        XCTAssertEqual(device.sync.pendingCameraDeletes, ["/mnt/card/video_front/a_f.ts": false])
        XCTAssertEqual(server.marked.map(\.id), [DashcamIDs.clipID(cameraID: "CAM", path: "/mnt/card/video_front/a_f.ts")])
        XCTAssertTrue(cam.deleted.isEmpty)
    }

    /// A card holding a tagged clip is never erased; one without is, as before.
    func testFormatIsRefusedWhileTheCardHoldsALockedClip() async throws {
        let server = FakeSyncServer()
        device.sync.server = server
        device.sync.defaults = UserDefaults(suiteName: "dashcam-device-\(UUID().uuidString)")!
        let tagged = DashcamFile(path: "/mnt/card/video_front/accident_f.ts", kind: .normal, lens: .front, start: Date(),
                                 durationS: 60, size: 10)
        let plain = DashcamFile(path: "/mnt/card/video_front/plain_f.ts", kind: .normal, lens: .front, start: Date(),
                                durationS: 60, size: 10)
        cam.files = [tagged, plain]
        DashcamTagged.mark(DashcamIDs.clipID(cameraID: "CAM", path: tagged.path), defaults: device.sync.defaults)
        do {
            _ = try await device.invoke("dashcam_format_sd", args: ["confirm": true])
            XCTFail("formatted a card with a locked clip")
        } catch {
            XCTAssertEqual(error.localizedDescription, DashcamDevice.formatRefusal(1))
            XCTAssertTrue(error.localizedDescription.contains("1 locked clip "), error.localizedDescription)
        }
        XCTAssertFalse(cam.calls.contains("format"))
        cam.files = [plain]
        let out = try await device.invoke("dashcam_format_sd", args: ["confirm": true])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertTrue(cam.calls.contains("format"))
    }

    private func lockedOnServer(_ path: String, onCamera: Bool = true) -> DashcamServerClip {
        DashcamServerClip(json: ["id": DashcamIDs.clipID(cameraID: "CAM", path: path), "camera_id": "CAM", "path": path,
                                 "tags": ["accident"], "locked": true, "on_camera": onCamera])!
    }

    /// No format on this phone's word alone: refused when the server can't be asked, and when the server knows of a
    /// locked clip on this camera's card that the listing missed.
    func testFormatNeedsTheServersListOfLockedClips() async throws {
        let server = FakeSyncServer()
        device.sync.server = server
        device.sync.defaults = UserDefaults(suiteName: "dashcam-device-\(UUID().uuidString)")!
        cam.files = [DashcamFile(path: "/mnt/card/video_front/plain_f.ts", kind: .normal, lens: .front, start: Date(),
                                 durationS: 60, size: 10)]
        server.unreachable = true
        do {
            _ = try await device.invoke("dashcam_format_sd", args: ["confirm": true])
            XCTFail("formatted without asking the server")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Couldn't ask the Jarvis server"), error.localizedDescription)
        }
        server.unreachable = false
        server.listed = [lockedOnServer("/mnt/card/video_back/accident_b.ts")]     // not in the (short) listing
        do {
            _ = try await device.invoke("dashcam_format_sd", args: ["confirm": true])
            XCTFail("formatted a card the server says holds a locked clip")
        } catch {
            XCTAssertEqual(error.localizedDescription, DashcamDevice.formatRefusal(1))
        }
        XCTAssertFalse(cam.calls.contains("format"))
    }

    /// Tagged on the web since this phone last heard: the delete tool asks the server before the file goes.
    func testDeleteFileAsksTheServerOnTheCameraWiFi() async throws {
        let server = FakeSyncServer()
        device.sync.server = server
        device.sync.defaults = UserDefaults(suiteName: "dashcam-device-\(UUID().uuidString)")!
        let path = "/mnt/card/video_front/2026-10-21_16_17_37_f.ts"
        server.listed = [lockedOnServer(path)]
        do {
            _ = try await device.invoke("dashcam_delete_file", args: ["path": path, "confirm": true])
            XCTFail("deleted a clip the server calls locked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("locked clip"), error.localizedDescription)
        }
        XCTAssertTrue(cam.deleted.isEmpty)
    }

    /// Jarvis's delete tool refuses a locked clip's file — on the camera's Wi‑Fi and away from it.
    func testDeleteFileRefusesALockedClip() async throws {
        let server = FakeSyncServer()
        device.sync.server = server
        device.sync.defaults = UserDefaults(suiteName: "dashcam-device-\(UUID().uuidString)")!
        let path = "/mnt/card/video_back/2026-10-21_16_17_37_b.ts"
        DashcamTagged.mark(DashcamIDs.clipID(cameraID: "CAM", path: path), defaults: device.sync.defaults)
        for away in [false, true] {
            onCamera = !away
            do {
                _ = try await device.invoke("dashcam_delete_file", args: ["path": path, "confirm": true])
                XCTFail("deleted a locked clip (away: \(away))")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("locked clip"), error.localizedDescription)
            }
        }
        XCTAssertTrue(cam.deleted.isEmpty)
        XCTAssertTrue(server.marked.isEmpty, "not queued either")
        XCTAssertTrue(device.sync.pendingCameraDeletes.isEmpty)
    }

    func testCameraCommandsNeedTheCameraWiFiButStatusDoesNot() async throws {
        onCamera = false
        do {
            _ = try await device.invoke("dashcam_lock_clip", args: [:])
            XCTFail("expected not connected")
        } catch {
            XCTAssertEqual(error as? DashcamError, .notConnected)
        }
        let status = try await device.invoke("dashcam_get_status", args: [:])
        XCTAssertEqual(status["on_camera_wifi"] as? Bool, false)
        XCTAssertEqual(status["camera"] as? String, "Affver")
    }

    func testDestructiveCommandsNeedConfirm() async {
        for skill in ["dashcam_format_sd", "dashcam_delete_file"] {
            do {
                _ = try await device.invoke(skill, args: ["path": "/x"])
                XCTFail("\(skill) ran without confirm")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("confirm=true"), "\(error)")
            }
        }
    }

    func testLockAndRecordingReachTheCamera() async throws {
        _ = try await device.invoke("dashcam_lock_clip", args: [:])
        XCTAssertTrue(cam.calls.contains("lock"))
        let r = try await device.invoke("dashcam_set_recording", args: ["enabled": false])
        XCTAssertEqual(r["recording"] as? Bool, false)
        do {
            _ = try await device.invoke("dashcam_set_recording", args: ["enabled": "yes"])
            XCTFail("a string is not a bool")
        } catch {}
    }

    func testStartingARecordingCameraIsNotAnError() async throws {
        // The phone showed "Stopped" from a stale read; the camera was recording and refused rec=1.
        cam.setFailsWhenSame = true
        cam.recordingOn = true
        let r = try await device.invoke("dashcam_set_recording", args: ["enabled": true])
        XCTAssertEqual(r["recording"] as? Bool, true)
        XCTAssertEqual(device.sync.recording, true)
        // A refusal that leaves it in the wrong state still surfaces.
        cam.setFailsWhenSame = false
        cam.recordingOn = false
        _ = try await device.invoke("dashcam_set_recording", args: ["enabled": false])
        XCTAssertEqual(device.sync.recording, false)
    }

    func testStatusIsReadOnItsOwnBetweenPasses() async {
        cam.recordingOn = false
        await device.sync.refreshStatus()
        XCTAssertEqual(device.sync.recording, false)
        cam.recordingOn = true                      // the camera started recording by itself
        await device.sync.refreshStatus()
        XCTAssertEqual(device.sync.recording, true)
        onCamera = false
        cam.recordingOn = false
        await device.sync.refreshStatus()           // off its Wi-Fi: nothing read
        XCTAssertEqual(device.sync.recording, true)
    }

    func testSettingValuesResolveFromCodeOrLabel() {
        let item = DashcamSettingItem(name: "speed_unit", value: "0",
                                      options: [.init(code: "0", label: "km/h"), .init(code: "1", label: "mph")])
        XCTAssertEqual(DashcamDevice.resolve("1", in: item), "1")
        XCTAssertEqual(DashcamDevice.resolve("MPH", in: item), "1")
        XCTAssertNil(DashcamDevice.resolve("knots", in: item))
        XCTAssertEqual(DashcamDevice.resolve("7", in: DashcamSettingItem(name: "ev", range: "0-10")), "7")
    }

    func testFetchRangeValidatesTimes() async throws {
        do {
            _ = try await device.invoke("dashcam_fetch_range", args: ["from": "yesterday", "to": "now"])
            XCTFail("bad times accepted")
        } catch {}
        let r = try await device.invoke("dashcam_fetch_range", args: ["from": "2026-10-01T20:38:00Z", "to": "2026-10-01T20:42:00Z"])
        XCTAssertEqual(r["ok"] as? Bool, true)
    }
}

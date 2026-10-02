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
                               "dashcam_format_sd", "dashcam_delete_file", "dashcam_set_wifi", "dashcam_fetch_range"])
        XCTAssertEqual(device.deviceID, "dashcam-CAM")
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

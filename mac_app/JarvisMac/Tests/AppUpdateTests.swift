import XCTest
@testable import Jarvis

/// The updater's pure rules: which build is newer, what the server's answer
/// decodes to, when Later keeps the pop-up hidden, and which unpacked app may
/// replace this one.
final class AppUpdateTests: XCTestCase {

    // MARK: build numbers

    func testStampedBuildsCompareAsNumbers() {
        XCTAssertEqual(AppUpdateRules.buildNumber("263021514"), 263021514)
        XCTAssertEqual(AppUpdateRules.buildNumber(NSNumber(value: 42)), 42)
        XCTAssertTrue(AppUpdateRules.isNewer(263021514, than: 263021459))
        XCTAssertFalse(AppUpdateRules.isNewer(263021514, than: 263021514))
        XCTAssertFalse(AppUpdateRules.isNewer(263021459, than: 263021514))
    }

    func testAnUnstampedBuildIsOlderThanAnyPublishedOne() {
        XCTAssertTrue(AppUpdateRules.isNewer(263021514, than: AppUpdateRules.buildNumber("1")))
        XCTAssertEqual(AppUpdateRules.buildNumber("1.0b"), 0)
        XCTAssertEqual(AppUpdateRules.buildNumber(nil), 0)
    }

    func testTheLatestURLCarriesPlatformAndBuild() {
        XCTAssertEqual(AppUpdateRules.latestURL(origin: "http://127.0.0.1:5123", build: 7)?.absoluteString,
                       "http://127.0.0.1:5123/api/app-updates/latest?platform=mac&build=7")
    }

    // MARK: the server's answer

    func testAnOfferDecodes() {
        let u = MacAppUpdate(json: ["available": true, "platform": "mac", "build": 263021514, "version": "1.0",
                                    "notes": " Faster island\n", "size": 31_000_000,
                                    "install_url": "https://vibeforge.example/ota/d/tok/Jarvis.zip"])
        XCTAssertEqual(u?.build, 263021514)
        XCTAssertEqual(u?.notes, "Faster island")
        XCTAssertEqual(u?.installURL.lastPathComponent, "Jarvis.zip")
    }

    func testNothingNewerOrAnUnusableAnswerIsNoOffer() {
        XCTAssertNil(MacAppUpdate(json: ["available": false, "build": 5]))
        XCTAssertNil(MacAppUpdate(json: ["available": true, "build": 5]))  // no URL
        XCTAssertNil(MacAppUpdate(json: ["available": true, "build": 5, "install_url": "http://x/Jarvis.zip"]))
        XCTAssertNil(MacAppUpdate(json: ["available": true, "platform": "ios", "build": 5,
                                         "install_url": "https://x/Jarvis.zip"]))
        XCTAssertNil(MacAppUpdate(json: ["available": true, "build": 0, "install_url": "https://x/Jarvis.zip"]))
    }

    // MARK: Later

    func testWithNothingPutOffEveryCheckShows() {
        let gate = AppUpdateGate()
        for t in [AppUpdateGate.Trigger.launch, .activation, .poll, .push] {
            XCTAssertTrue(gate.shouldShow(build: 9, trigger: t))
        }
    }

    func testLaterHidesThatBuildFromPollsAndPushes() {
        var gate = AppUpdateGate()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.later(build: 9, at: t0)
        let later = t0.addingTimeInterval(3600)
        XCTAssertFalse(gate.shouldShow(build: 9, trigger: .poll, now: later))
        XCTAssertFalse(gate.shouldShow(build: 9, trigger: .push, now: later))
        XCTAssertFalse(gate.shouldShow(build: 8, trigger: .poll, now: later))
    }

    func testActivationShowsItAgainOnlyAfterFifteenMinutes() {
        var gate = AppUpdateGate()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.later(build: 9, at: t0)
        XCTAssertFalse(gate.shouldShow(build: 9, trigger: .activation, now: t0.addingTimeInterval(14 * 60)))
        XCTAssertTrue(gate.shouldShow(build: 9, trigger: .activation, now: t0.addingTimeInterval(15 * 60)))
    }

    func testANewerBuildShowsDespiteLater() {
        var gate = AppUpdateGate()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        gate.later(build: 9, at: t0)
        XCTAssertTrue(gate.shouldShow(build: 10, trigger: .push, now: t0.addingTimeInterval(5)))
    }

    // MARK: verifying the unpacked app

    func testOnlyThisAppAtTheOfferedBuildPasses() {
        let ok: [String: Any] = ["CFBundleIdentifier": "com.jarviscopilot.mac", "CFBundleVersion": "263021514"]
        XCTAssertNil(AppUpdateRules.problem(info: ok, bundleID: "com.jarviscopilot.mac", build: 263021514))
        XCTAssertNotNil(AppUpdateRules.problem(info: ok, bundleID: "com.example.other", build: 263021514))
        XCTAssertNotNil(AppUpdateRules.problem(info: ok, bundleID: "com.jarviscopilot.mac", build: 263021515))
        XCTAssertNotNil(AppUpdateRules.problem(info: nil, bundleID: "com.jarviscopilot.mac", build: 263021514))
    }

    func testAFakeUnpackedBundleIsReadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-update-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Jarvis.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.jarviscopilot.mac", "CFBundleVersion": "263021514"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(AppUpdateRules.problem(appAt: app, bundleID: "com.jarviscopilot.mac", build: 263021514))
        XCTAssertNotNil(AppUpdateRules.problem(appAt: app, bundleID: "com.jarviscopilot.mac", build: 263021600))
        XCTAssertNotNil(AppUpdateRules.problem(appAt: dir.appendingPathComponent("Missing.app"),
                                               bundleID: "com.jarviscopilot.mac", build: 263021514))
    }

    // MARK: signatures

    func testThisAppPassesItsOwnRequirement() throws {
        try XCTSkipIf(AppUpdateRules.signatureProblem(appAt: Bundle.main.bundleURL)?.contains("developer certificate") == true,
                      "the test host isn't signed with a developer certificate")
        XCTAssertNil(AppUpdateRules.signatureProblem(appAt: Bundle.main.bundleURL))
    }

    func testAnotherSignedAppOrAnUnsignedBundleFails() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        XCTAssertNotNil(AppUpdateRules.signatureProblem(appAt: calculator))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-sig-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("Jarvis.app/Contents")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.jarviscopilot.mac"],
                                           format: .xml, options: 0)
            .write(to: fake.appendingPathComponent("Info.plist"))
        XCTAssertNotNil(AppUpdateRules.signatureProblem(appAt: dir.appendingPathComponent("Jarvis.app")))
    }

    func testAnAppWithoutATeamCantVouchForAnUpdate() throws {
        var apple: SecStaticCode?
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(SecStaticCodeCreateWithPath(calculator as CFURL, [], &apple) == errSecSuccess)
        let problem = AppUpdateRules.signatureProblem(appAt: Bundle.main.bundleURL, own: apple)
        XCTAssertTrue(problem?.contains("developer certificate") == true, problem ?? "nil")
    }
}

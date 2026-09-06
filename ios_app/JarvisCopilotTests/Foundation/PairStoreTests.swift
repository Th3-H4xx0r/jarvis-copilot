import XCTest
@testable import JarvisCopilot

/// Stands in for `BridgeClient` so the state machine can be driven without a
/// server, a Keychain write or a camera.
@MainActor
final class MockPairing: PairingClaiming {
    var serverURL = ""
    var isPaired = false
    var appliedCFClientID: String?
    var appliedCFClientSecret: String?
    /// Codes passed to `claim`, in order.
    var claimedCodes: [String] = []
    /// Whether the Cloudflare token was already applied when `claim` ran — the
    /// tunnel rejects the claim otherwise.
    var cfWasAppliedBeforeClaim = false
    var serverURLAtClaim: String?
    var failure: Error?

    func applyScanned(cfClientID: String?, cfClientSecret: String?) {
        if let cfClientID, !cfClientID.isEmpty { appliedCFClientID = cfClientID }
        if let cfClientSecret, !cfClientSecret.isEmpty { appliedCFClientSecret = cfClientSecret }
    }

    func claim(code: String) async throws {
        claimedCodes.append(code)
        cfWasAppliedBeforeClaim = appliedCFClientID != nil && appliedCFClientSecret != nil
        serverURLAtClaim = serverURL
        if let failure { throw failure }
        isPaired = true
    }
}

@MainActor
final class MockQRScanner: QRScanning {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var isRunning: Bool { startCount > stopCount }
    private var sink: ((String) -> Void)?

    func start(onCode: @escaping (String) -> Void) {
        startCount += 1
        sink = onCode
    }

    func stop() {
        stopCount += 1
        sink = nil
    }

    /// Simulate the camera decoding a barcode.
    func emit(_ raw: String) { sink?(raw) }
}

@MainActor
final class PairStoreTests: XCTestCase {

    private func makeStore() -> (PairStore, MockPairing, MockQRScanner, MemoryKeyValueStore) {
        let pairing = MockPairing()
        let scanner = MockQRScanner()
        let prefs = MemoryKeyValueStore()
        let store = PairStore(pairing: pairing, scanner: scanner, preferences: prefs)
        return (store, pairing, scanner, prefs)
    }

    // MARK: Scanning

    func testStartScanningRunsTheCameraAndClearsAnyError() {
        let (store, _, scanner, _) = makeStore()
        store.errorMessage = "stale"
        store.startScanning()
        XCTAssertEqual(store.phase, .scanning)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(scanner.isRunning)
    }

    func testCancelScanningStopsTheCameraAndReturnsToTheForm() {
        let (store, _, scanner, _) = makeStore()
        store.startScanning()
        store.cancelScanning()
        XCTAssertEqual(store.phase, .form)
        XCTAssertFalse(scanner.isRunning)
    }

    func testScannedDeepLinkFillsTheFormAndLeavesTheScanner() {
        let (store, _, scanner, _) = makeStore()
        store.startScanning()
        scanner.emit("jarviscopilot://pair?server=https://jarvis.test&code=ABC-DEF"
                   + "&cf_id=xxxx.access&cf_secret=s3cret")

        XCTAssertEqual(store.serverURL, "https://jarvis.test")
        XCTAssertEqual(store.code, "ABC-DEF")
        XCTAssertEqual(store.cfClientID, "xxxx.access")
        XCTAssertEqual(store.cfClientSecret, "s3cret")
        // The section must be open, otherwise a scanned token looks "not copied".
        XCTAssertTrue(store.showsCloudflareFields)
        XCTAssertEqual(store.phase, .form)
        XCTAssertFalse(scanner.isRunning)
    }

    func testScannedServerURLOnlyLeavesTheCodeForTheUser() {
        let (store, _, scanner, _) = makeStore()
        store.startScanning()
        scanner.emit("https://jarvis.example.com/pair")
        XCTAssertEqual(store.serverURL, "https://jarvis.example.com")
        XCTAssertEqual(store.code, "")
        XCTAssertFalse(store.showsCloudflareFields)
    }

    func testUnrecognisedScanKeepsTheCameraOpen() {
        let (store, _, scanner, _) = makeStore()
        store.startScanning()
        XCTAssertFalse(store.handleScan("WIFI:S:home;;"))
        XCTAssertEqual(store.phase, .scanning, "the user must be able to try another code")
        XCTAssertTrue(scanner.isRunning)
        XCTAssertNotNil(store.errorMessage)
    }

    func testAScanNeverBlanksAFieldTheUserAlreadyFilled() {
        let (store, _, scanner, _) = makeStore()
        store.code = "TYPED"
        store.startScanning()
        scanner.emit("https://jarvis.test")
        XCTAssertEqual(store.code, "TYPED")
    }

    // MARK: Submitting

    func testSubmitRequiresBothFields() async {
        let (store, pairing, _, _) = makeStore()
        await store.submit()
        XCTAssertEqual(store.errorMessage, "Server URL and code are required")
        XCTAssertEqual(store.phase, .form)
        XCTAssertTrue(pairing.claimedCodes.isEmpty)

        store.serverURL = "https://jarvis.test"
        await store.submit()
        XCTAssertEqual(store.errorMessage, "Server URL and code are required")
        XCTAssertTrue(pairing.claimedCodes.isEmpty)
    }

    /// The session cookie is the whole credential; handing it to plain http would
    /// put it on the wire in the clear.
    func testSubmitRefusesAnExplicitHttpServer() async {
        let (store, pairing, _, _) = makeStore()
        store.serverURL = "http://192.168.1.5:8787"
        store.code = "ABC"
        await store.submit()
        XCTAssertEqual(store.errorMessage, "Server URL must be https://")
        XCTAssertTrue(pairing.claimedCodes.isEmpty)
    }

    func testSubmitAcceptsABareHostBecauseTheBridgeAssumesHttps() async {
        let (store, pairing, _, _) = makeStore()
        store.serverURL = "jarvis.example.com"
        store.code = "abc"
        await store.submit()
        XCTAssertEqual(pairing.serverURLAtClaim, "jarvis.example.com")
        XCTAssertEqual(store.phase, .paired)
    }

    func testSubmitUppercasesTheCodeAndTrimsBothFields() async {
        let (store, pairing, _, _) = makeStore()
        store.serverURL = "  https://jarvis.test  "
        store.code = " abc-def "
        await store.submit()
        XCTAssertEqual(pairing.claimedCodes, ["ABC-DEF"])
        XCTAssertEqual(pairing.serverURLAtClaim, "https://jarvis.test")
    }

    func testSubmitAppliesTheCloudflareTokenBeforeClaiming() async {
        let (store, pairing, _, _) = makeStore()
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"
        store.cfClientID = "xxxx.access"
        store.cfClientSecret = "s3cret"
        await store.submit()
        XCTAssertTrue(pairing.cfWasAppliedBeforeClaim,
                      "a tunnel-fronted server 302s the claim without CF-Access headers")
        XCTAssertEqual(pairing.appliedCFClientID, "xxxx.access")
    }

    func testSubmitSkipsAHalfFilledCloudflareToken() async {
        let (store, pairing, _, _) = makeStore()
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"
        store.cfClientID = "xxxx.access"
        await store.submit()
        XCTAssertNil(pairing.appliedCFClientID)
    }

    func testSuccessfulSubmitPersistsTheDeviceName() async {
        let (store, _, _, prefs) = makeStore()
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"
        store.deviceName = "Work iPhone"
        await store.submit()
        XCTAssertEqual(prefs.string(SettingsStore.Keys.deviceName), "Work iPhone")
    }

    func testFailedSubmitReportsTheMessageAndReturnsToTheForm() async {
        let (store, pairing, _, _) = makeStore()
        pairing.failure = BridgeError.message("Pairing failed (403)")
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"
        await store.submit()
        XCTAssertEqual(store.phase, .form)
        XCTAssertEqual(store.errorMessage, "Pair failed: Pairing failed (403)")
    }

    func testCanSubmitTracksTheRequiredFields() {
        let (store, _, _, _) = makeStore()
        XCTAssertFalse(store.canSubmit)
        store.serverURL = "https://jarvis.test"
        XCTAssertFalse(store.canSubmit)
        store.code = "ABC"
        XCTAssertTrue(store.canSubmit)
    }

    func testADeviceNameDefaultsToTheHardwareLabel() {
        let (store, _, _, _) = makeStore()
        XCTAssertFalse(store.deviceName.isEmpty)
    }

    /// A scanned http:// QR is refused at parse time now, so the store treats it
    /// as an unrecognised code and keeps the camera up.
    func testAnHttpQRIsNotAccepted() {
        let (store, _, scanner, _) = makeStore()
        store.startScanning()
        XCTAssertFalse(store.handleScan("http://192.168.1.5:8787"))
        XCTAssertEqual(store.serverURL, "")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(scanner.isRunning, "an unrecognised code leaves the camera running")
    }

    // MARK: A new server invalidates what we learned about the old one

    /// `ChatAPI`'s streaming-start probe is process-wide ("one server per app
    /// session"), and nothing ever cleared it: pairing onto a server of the other
    /// vintage kept the previous verdict for the rest of the launch, so every
    /// turn took the wrong path — an extra doomed probe per turn, or the fast
    /// path against a server that does not have it.
    func testASuccessfulPairForgetsWhatWeLearnedAboutTheOldServer() async {
        var resets = 0
        let store = PairStore(pairing: MockPairing(), scanner: MockQRScanner(),
                              preferences: MemoryKeyValueStore(),
                              onServerChanged: { resets += 1 })
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"

        await store.submit()

        XCTAssertEqual(store.phase, .paired)
        XCTAssertEqual(resets, 1)
    }

    /// A claim that failed left us on the SAME server; re-probing it is pure cost.
    func testAFailedPairLeavesTheProbeAlone() async {
        var resets = 0
        let pairing = MockPairing()
        pairing.failure = APIError.http(status: 401, message: "bad code")
        let store = PairStore(pairing: pairing, scanner: MockQRScanner(),
                              preferences: MemoryKeyValueStore(),
                              onServerChanged: { resets += 1 })
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"

        await store.submit()

        XCTAssertEqual(store.phase, .form)
        XCTAssertEqual(resets, 0)
    }

    /// …and the production default really is `ChatAPI.resetFeatureDetection()`,
    /// not just some closure nobody wired up.
    func testTheDefaultHookClearsChatsFeatureProbe() async {
        ChatAPI.streamingStartSupported = true
        let (store, _, _, _) = makeStore()
        store.serverURL = "https://jarvis.test"
        store.code = "ABC"

        await store.submit()

        XCTAssertNil(ChatAPI.streamingStartSupported, "a re-pair must re-probe the new server")
    }

    // MARK: the camera itself

    /// `start`/`stop` used to go to unordered `Task.detached`s, so a start could
    /// land after the stop that was meant to cancel it and leave the camera on.
    /// They are serialised now; these calls must be safe in any order, including
    /// on a device with no camera at all (the simulator).
    func testTheCameraScannerToleratesAnyStartStopOrder() {
        let camera = CameraQRScanner()
        camera.stop()                        // before any start
        camera.start { _ in }
        camera.stop()
        camera.start { _ in }
        camera.start { _ in }                // replacing the sink is allowed
        camera.stop()
        camera.stop()
        // A camera-less device says so rather than showing a black rectangle.
        #if targetEnvironment(simulator)
        XCTAssertEqual(camera.failureMessage,
                       "No camera available. Type the pairing code instead.")
        #endif
    }
}

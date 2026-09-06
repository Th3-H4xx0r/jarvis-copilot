import Foundation
import XCTest
@testable import JarvisCopilot

/// `services/push_handler.dart`'s token registration — the half `PushService`
/// (silent-push plumbing) never had: the device NAME, and storing the server's
/// `device_id` (the Flutter `credentials.dart` field the Live Activity token
/// registration needs).
@MainActor
final class PushHandlerTests: XCTestCase {

    func testRegistrationBodyCarriesEverythingTheServerRoutesOn() {
        let registration = PushTokenRegistration(
            token: "deadbeef", deviceName: "Pranav's iPhone",
            bundleID: "com.jarviscopilot.jarviscopilotMobileAndIOS", pushEnvironment: "development",
            appVersion: "1.0")
        let body = registration.json

        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["push_kind"] as? String, "apns",
                       "a REAL APNs token, not an FCM one — the server picks its sender from this")
        XCTAssertEqual(body["push_token"] as? String, "deadbeef")
        XCTAssertEqual(body["device_name"] as? String, "Pranav's iPhone")
        XCTAssertEqual(body["bundle_id"] as? String, "com.jarviscopilot.jarviscopilotMobileAndIOS",
                       "the APNs topic is the bundle id; without it the server pushes to the wrong app")
        XCTAssertEqual(body["push_env"] as? String, "development",
                       "a sandbox token is only valid against the APNs sandbox host")
        XCTAssertEqual(body["app_version"] as? String, "1.0")
    }

    func testANamelessDeviceOmitsTheKeyRatherThanSendingEmpty() {
        let body = PushTokenRegistration(
            token: "t", deviceName: "", bundleID: "b",
            pushEnvironment: "production", appVersion: "1.0").json
        XCTAssertNil(body["device_name"], "an empty name would relabel the row as ''")
    }

    func testRegisterTokenPostsAndStoresTheServerDeviceID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "device_id": "dev-42"])
        let preferences = MemoryKeyValueStore([SettingsStore.Keys.deviceName: "Test Phone"])
        let handler = PushHandler(api: api, preferences: preferences, sleeper: { _ in })

        await handler.registerToken("abc123")

        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/devices/mobile/token")
        XCTAssertEqual(transport.lastBody()["push_token"] as? String, "abc123")
        XCTAssertEqual(transport.lastBody()["device_name"] as? String, "Test Phone")
        XCTAssertEqual(handler.deviceID, "dev-42")
        XCTAssertEqual(preferences.string(PushHandler.deviceIDKey), "dev-42")
    }

    func testAnEmptyTokenIsNeverSent() async {
        let (api, transport) = JarvisAPI.mocked()
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })
        await handler.registerToken("")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAFailedRegistrationLeavesNoDeviceID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "nope"], status: 500)
        let preferences = MemoryKeyValueStore()
        let handler = PushHandler(api: api, preferences: preferences, sleeper: { _ in })

        await handler.registerToken("abc123")

        XCTAssertNil(handler.deviceID, "no id until a post actually lands")
        XCTAssertEqual(transport.requests.count, PushHandler.registrationRetryDelays.count + 1,
                       "every attempt failed, so all of them were tried")
    }

    func testAReplyWithoutADeviceIdKeepsThePreviousOne() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let preferences = MemoryKeyValueStore([PushHandler.deviceIDKey: "dev-old"])
        let handler = PushHandler(api: api, preferences: preferences, sleeper: { _ in })

        await handler.registerToken("abc123")
        XCTAssertEqual(handler.deviceID, "dev-old")
    }

    // MARK: One registration per token per launch

    /// `PushService.submit` posts the token twice — once through
    /// `BridgeClient.registerPush` and once here — and iOS re-delivers the same
    /// token on every launch. The row is an upsert, so the duplicate is harmless
    /// but wasted; drop it.
    func testTheSameTokenIsOnlyRegisteredOnce() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "device_id": "dev-1"])
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })

        await handler.registerToken("abc123")
        await handler.registerToken("abc123")

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(handler.lastSentToken, "abc123")
    }

    /// APNs tokens rotate; a new one is a real change and must go through.
    func testARotatedTokenIsRegisteredAgain() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        transport.enqueue(json: ["ok": true])
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })

        await handler.registerToken("abc123")
        await handler.registerToken("def456")

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.lastBody()["push_token"] as? String, "def456")
    }

    /// A transient failure is retried in place. A device without a registered
    /// token gets NO pushes at all — no coding approvals, no deferred-action
    /// banners — so waiting for the next cold launch was never good enough.
    func testATransientFailureIsRetriedUntilItLands() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "boom"], status: 500)
        transport.enqueue(json: ["ok": true, "device_id": "dev-2"])
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })

        await handler.registerToken("abc123")

        XCTAssertEqual(transport.requests.count, 2, "the 500 was retried, not dropped")
        XCTAssertEqual(handler.registrationAttempts, 2)
        XCTAssertEqual(handler.lastSentToken, "abc123")
        XCTAssertNil(handler.lastRegistrationError, "the retry landed")
        XCTAssertEqual(handler.deviceID, "dev-2")
    }

    /// Only a SUCCESSFUL post counts — a token that never registered has to stay
    /// retryable on the next launch rather than being remembered as sent.
    func testARegistrationThatFailsEveryAttemptStaysRetryable() async {
        let (api, transport) = JarvisAPI.mocked()
        for _ in 0...PushHandler.registrationRetryDelays.count {
            transport.enqueue(json: ["error": "boom"], status: 500)
        }
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })

        await handler.registerToken("abc123")

        XCTAssertNil(handler.lastSentToken)
        XCTAssertEqual(transport.requests.count, PushHandler.registrationRetryDelays.count + 1)
        XCTAssertNotNil(handler.lastRegistrationError,
                        "a phone that never registered must not look identical to one that did")
    }

    /// The retries stop when the app is going away — firing the request into a
    /// dying process just burns the token's last chance.
    func testACancelledBackoffStopsRetrying() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "boom"], status: 500)
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(),
                                  sleeper: { _ in throw CancellationError() })

        await handler.registerToken("abc123")

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(handler.lastSentToken)
    }

    // MARK: Notification authorization

    /// A refusal is not an error path anywhere — nothing throws, the banners
    /// simply never appear — so it has to be written down or the user has no way
    /// to find out that approvals are going nowhere.
    func testARefusedNotificationPermissionIsRecordedForSettings() {
        let (api, _) = JarvisAPI.mocked()
        let preferences = MemoryKeyValueStore()
        let handler = PushHandler(api: api, preferences: preferences, sleeper: { _ in })

        handler.recordNotificationAuthorization(false)

        XCTAssertEqual(handler.notificationsGranted, false)
        XCTAssertEqual(preferences.bool(SettingsStore.Keys.notificationsGranted), false)

        let store = SettingsStore(preferences: preferences, bridge: MockSettingsBridge(),
                                  location: MockLocationTracking(),
                                  liveActivity: MockLiveActivityToggling(),
                                  website: MockWebsiteCleaner())
        XCTAssertTrue(store.notificationsAreOff, "Settings shows the row off the same flag")
    }

    func testAGrantedNotificationPermissionIsRecordedToo() {
        let (api, _) = JarvisAPI.mocked()
        let preferences = MemoryKeyValueStore()
        let handler = PushHandler(api: api, preferences: preferences, sleeper: { _ in })

        handler.recordNotificationAuthorization(true)

        XCTAssertEqual(preferences.bool(SettingsStore.Keys.notificationsGranted), true)
        XCTAssertFalse(SettingsStore(preferences: preferences, bridge: MockSettingsBridge(),
                                     location: MockLocationTracking(),
                                     liveActivity: MockLiveActivityToggling(),
                                     website: MockWebsiteCleaner()).notificationsAreOff)
    }

    /// nil, not false: nobody has asked yet, so Settings must not claim they are off.
    func testTheFlagStartsUnknown() {
        let (api, _) = JarvisAPI.mocked()
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })
        XCTAssertNil(handler.notificationsGranted)
    }

    func testTheDeviceNameFallsBackToThisDevicesName() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let handler = PushHandler(api: api, preferences: MemoryKeyValueStore(), sleeper: { _ in })

        await handler.registerToken("abc123")
        XCTAssertEqual(transport.lastBody()["device_name"] as? String,
                       SettingsStore.defaultDeviceName)
    }
}

import XCTest
@testable import JarvisCopilot

final class InmoProtocolTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = hex.filter { !$0.isWhitespace }; var result = Data(); var i = text.startIndex
        while i < text.endIndex { let end = text.index(i, offsetBy: 2); result.append(UInt8(text[i..<end], radix: 16)!); i = end }; return result
    }
    func testObservedRemoteGoldens() throws {
        XCTAssertEqual(InmoCommand.home(), data("080110022a020805"))
        XCTAssertEqual(InmoCommand.back(), data("080110022a020804"))
        XCTAssertEqual(try InmoCommand.touch(kind: 2, direction: 3, x: 100, y: 51), data("080110022a0c080842080802100318642033"))
        XCTAssertEqual(try InmoCommand.touch(kind: 1, direction: nil, x: 71, y: 52), data("080110022a0a08084206080118472034"))
        XCTAssertEqual(InmoCommand.mediaInventory(), data("1011a20106080432020804"))
        XCTAssertEqual(InmoCommand.wifi(open: true), data("1011a2010608032a020800"))
        XCTAssertEqual(InmoCommand.enableClassicGATT(), data("08011011a2010408035000"))
    }
    // Schema-composed (not yet an observed golden): the remote's GO button is CommandType.GO_INDEX(7),
    // in the same Control message as BACK_INDEX(4) and HOME_INDEX(5), whose bytes are observed above.
    // A double press is two of them inside the glasses' double-click window.
    func testGoButtonIsGoIndexInTheRemoteControlMessage() {
        XCTAssertEqual(InmoCommand.go(), data("080110022a020807"))
        XCTAssertEqual(InmoCommand.goDouble(), [data("080110022a020807"), data("080110022a020807")])
        XCTAssertLessThan(InmoCommand.doublePressGap, 0.4)
    }
    // Schema-composed (not an observed golden): GlassesSettings{msgType: IOS_ANCS_ENABLE(24), isOpen}.
    // version=1, MessageType.GLASSES_SETTINGS(19) at tag 2, GlassesSettings at field 22,
    // nested msgType(1)=24 (0x18) and isOpen(2)=1. Proves the wire bytes before the hardware ANCS test.
    func testAncsEnableWireBytes() throws {
        XCTAssertEqual(InmoCommand.iosAncsEnable(true), data("08011013b2010408181001"))
        XCTAssertEqual(InmoCommand.iosAncsEnable(false), data("08011013b2010408181000"))
    }
    // Observed golden (official INMO iOS app, 2026-09-26): the per-app notification list entry
    // GlassesSettings{msgType: MOBILE_NOTIFY_CIRCULATION_MODEL(15), 11: {appName "Gmail", isOpen 1}}.
    // Switching an app off omits isOpen, exactly as the official app does.
    func testNotificationAppListGolden() throws {
        XCTAssertEqual(InmoCommand.notificationApp("Gmail", enabled: true), data("08011013b2010d080f5a090a05476d61696c1001"))
        XCTAssertEqual(InmoCommand.notificationApp("Google Chrome", enabled: false), data("08011013b20113080f5a0f0a0d476f6f676c65204368726f6d65"))
    }
    // Same shape as the official app's reply (captured 2026-09-26, no version field): the glasses relay
    // an incoming call's number over MESSAGE_REMINDER USER_CALL_INFO; the phone answers with the name.
    func testCallInfoReplyMatchesOfficialShape() {
        XCTAssertEqual(InmoCommand.callInfo(name: "Dad", number: "+15550100000", state: 4),
                       data("10043a1d08011a190a050a03446164120e0a0c2b31353535303130303030302004"))
    }
    func testIncomingCallInfoParses() throws {
        let relayed = try InmoWireCodec.decode(data("080110043a1808011a140a00120e0a0c2b31353535303130303030302001"))
        let call = try XCTUnwrap(InmoCallInfo.parse(relayed))
        XCTAssertEqual(call.number, "+15550100000")
        XCTAssertNil(call.name)
        XCTAssertEqual(call.state, 1)
        XCTAssertNil(InmoCallInfo.parse(try InmoWireCodec.decode(InmoCommand.appNotification(title: "a", content: "b"))))
    }
    func testContactNameMatchesOnTrailingDigits() {
        let book = [ContactRecord(name: "Dad", phones: ["(555) 010-0000"]), ContactRecord(name: "Work", phones: ["+44 20 7946 0000"])]
        XCTAssertEqual(ContactLookup.nameForNumber(book, number: "+15550100000"), "Dad")
        XCTAssertEqual(ContactLookup.nameForNumber(book, number: "5550100000"), "Dad")
        XCTAssertNil(ContactLookup.nameForNumber(book, number: "+15550199999"))
        XCTAssertNil(ContactLookup.nameForNumber(book, number: "12"))
    }
    // A card that arrives while the link is down (a push waking the app) waits for ready, briefly.
    func testPendingCardsKeepNewestThreeAndExpire() {
        var pending = InmoPendingCards(limit: 3, lifetime: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 1...4 { pending.add(title: "T\(i)", body: "B\(i)", now: t0.addingTimeInterval(Double(i))) }
        let drained = pending.drain(now: t0.addingTimeInterval(10))
        XCTAssertEqual(drained.map(\.title), ["T2", "T3", "T4"])
        XCTAssertTrue(pending.drain(now: t0.addingTimeInterval(11)).isEmpty)
        pending.add(title: "Old", body: "x", now: t0)
        XCTAssertTrue(pending.drain(now: t0.addingTimeInterval(61)).isEmpty)
    }
    // One visible push reaches both PushService and PushHandler.willPresent; the lens must show it once.
    func testCardDeduperDropsTheSameCardWithinWindow() {
        var deduper = InmoCardDeduper(window: 5)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(deduper.shouldSend(title: "Claude finished", body: "ios_app", now: t0))
        XCTAssertFalse(deduper.shouldSend(title: "Claude finished", body: "ios_app", now: t0.addingTimeInterval(0.03)))
        XCTAssertTrue(deduper.shouldSend(title: "Claude finished", body: "other", now: t0.addingTimeInterval(0.05)))
        XCTAssertTrue(deduper.shouldSend(title: "Claude finished", body: "ios_app", now: t0.addingTimeInterval(6)))
    }
    // Incoming MESSAGE_REMINDER summaries carry the app and sizes only — never the notification text.
    func testReminderSummaryNeverIncludesContent() throws {
        let relayed = try InmoWireCodec.decode(InmoCommand.appNotification(title: "Secret title", content: "Secret body", packageName: "com.example.chat", timeMillis: 1000))
        let summary = InmoReminderSummary.describe(relayed)
        XCTAssertTrue(summary.contains("app=com.example.chat"), summary)
        XCTAssertTrue(summary.contains("title=12B"), summary)
        XCTAssertTrue(summary.contains("content=11B"), summary)
        XCTAssertFalse(summary.contains("Secret"), summary)
        let call = try InmoWireCodec.decode(data("080110043a1408011a100a00120a0a0831323334353637382001"))
        XCTAssertTrue(InmoReminderSummary.describe(call).contains("call state=1"), InmoReminderSummary.describe(call))
        XCTAssertFalse(InmoReminderSummary.describe(call).contains("12345678"))
    }
    // MESSAGE_REMINDER(4) at Message field 7; MessageReminder{ field2: AppNotificationInfo }
    // with msgType APP_NOTIFICATION_INFO(0) omitted (proto3 default). AppNotificationInfo:
    // 1=packageName "a", 3=title "Hi", 4=content "Yo", 5=time 1000ms; type 0 omitted.
    func testAppNotificationWireBytes() throws {
        XCTAssertEqual(InmoCommand.appNotification(title: "Hi", content: "Yo", packageName: "a", type: 0, timeMillis: 1000),
                       data("080110043a10120e0a01611a0248692202596f28e807"))
    }
    func testCapturedFrameAndSplitInput() throws {
        let payload = try InmoCommand.brightness(50)
        let golden = data("aa55043c000100000301000c080110022a0608012a02083252cd")
        XCTAssertEqual(try InmoBluetoothFrameCodec.frames(payload: payload, id: 0x043c, maximumFrameLength: 512), [golden])
        let codec = InmoBluetoothFrameCodec(); let session = UUID()
        XCTAssertTrue(codec.consume(Data(golden.prefix(7)), session: session, channel: "test").isEmpty)
        XCTAssertEqual(codec.consume(Data(golden.dropFirst(7)), session: session, channel: "test"), [payload])
        var damaged = golden; damaged[15] ^= 1
        XCTAssertTrue(codec.consume(damaged, session: session, channel: "test").isEmpty)
        XCTAssertEqual(codec.counters.invalidFrames, 1)
    }
    func testFragmentOrderIsolationAndExpiry() throws {
        let payload = Data(repeating: 42, count: 100)
        let frames = try InmoBluetoothFrameCodec.frames(payload: payload, id: 1, maximumFrameLength: 40)
        let codec = InmoBluetoothFrameCodec(); let session = UUID(); let now = Date()
        XCTAssertTrue(codec.consume(frames[0], session: session, channel: "a", now: now).isEmpty)
        XCTAssertTrue(codec.consume(frames[1], session: session, channel: "b", now: now).isEmpty)
        for frame in frames.dropFirst().reversed() { let outputs = codec.consume(frame, session: session, channel: "a", now: now); if frame == frames[1] { XCTAssertEqual(outputs, [payload]) } }
        _ = codec.consume(Data(), session: session, channel: "b", now: now.addingTimeInterval(11))
        XCTAssertEqual(codec.counters.expiredAssemblies, 1)
    }
    func testDefaultsAndMalformedBounds() throws {
        let f = try InmoWireCodec.decode(data("100b7204080c7200"))
        XCTAssertEqual(try f.firstField(14)?.nested().firstField(14)?.bytes, Data())
        XCTAssertThrowsError(try InmoWireCodec.decode(data("0080")))
        XCTAssertThrowsError(try InmoWireCodec.decode(data("08ffffffffffffffffff02")))
        XCTAssertThrowsError(try InmoCommand.brightness(101))
        XCTAssertThrowsError(try InmoCommand.screenTimeout(seconds: 45))
        var status = InmoDeviceStatus()
        try status.apply(type: 20, fields: InmoWireCodec.decode(data("1014ba010608084a02081e")))
        XCTAssertEqual(status.volume, 30); XCTAssertNil(status.battery)
    }
    func testInterleavedSplitCharacteristicsAndSessions() throws {
        let a = try InmoBluetoothFrameCodec.frames(payload: Data([1, 2]), id: 3, maximumFrameLength: 100)[0]
        let b = try InmoBluetoothFrameCodec.frames(payload: Data([4, 5]), id: 3, maximumFrameLength: 100)[0]
        let codec = InmoBluetoothFrameCodec(); let first = UUID(); let second = UUID()
        XCTAssertTrue(codec.consume(Data(a.prefix(8)), session: first, channel: "a").isEmpty)
        XCTAssertTrue(codec.consume(Data(b.prefix(8)), session: first, channel: "b").isEmpty)
        XCTAssertTrue(codec.consume(Data(b.prefix(8)), session: second, channel: "a").isEmpty)
        XCTAssertEqual(codec.consume(Data(a.dropFirst(8)), session: first, channel: "a"), [Data([1, 2])])
        XCTAssertEqual(codec.consume(Data(b.dropFirst(8)), session: first, channel: "b"), [Data([4, 5])])
        XCTAssertEqual(codec.consume(Data(b.dropFirst(8)), session: second, channel: "a"), [Data([4, 5])])
        XCTAssertEqual(codec.counters.invalidFrames, 0)
    }
    func testBatteryFreshnessOnlyAdvancesForValidBatteryReceipt() throws {
        var status = InmoDeviceStatus(); let start = Date(timeIntervalSince1970: 100)
        let battery = InmoWireCodec.bytes(23, InmoWireCodec.bytes(8, InmoWireCodec.uint(1, 50)))
        try status.apply(type: 20, fields: InmoWireCodec.decode(battery), now: start)
        XCTAssertEqual(status.batteryObservedAt, start)
        let volume = InmoWireCodec.bytes(23, InmoWireCodec.bytes(9, InmoWireCodec.uint(1, 30)))
        try status.apply(type: 20, fields: InmoWireCodec.decode(volume), now: start.addingTimeInterval(60))
        XCTAssertEqual(status.batteryObservedAt, start)
        let invalid = InmoWireCodec.bytes(23, InmoWireCodec.bytes(8, InmoWireCodec.uint(1, 101)))
        try status.apply(type: 20, fields: InmoWireCodec.decode(invalid), now: start.addingTimeInterval(120))
        XCTAssertEqual(status.battery, 50)
        XCTAssertEqual(status.batteryObservedAt, start)
        let zero = InmoWireCodec.bytes(23, InmoWireCodec.bytes(8, Data()))
        try status.apply(type: 20, fields: InmoWireCodec.decode(zero), now: start.addingTimeInterval(180))
        XCTAssertEqual(status.battery, 0)
        XCTAssertEqual(status.batteryObservedAt, start.addingTimeInterval(180))
    }

    func testOversizedStatusEnumsThrowInsteadOfTrapping() throws {
        var status = InmoDeviceStatus()
        let module = InmoWireCodec.bytes(18, InmoWireCodec.uint(1, UInt64.max))
        XCTAssertThrowsError(try status.apply(type: 15, fields: InmoWireCodec.decode(module)))
        let timeout = InmoWireCodec.bytes(23, InmoWireCodec.bytes(4, InmoWireCodec.uint(1, UInt64.max)))
        XCTAssertThrowsError(try status.apply(type: 20, fields: InmoWireCodec.decode(timeout)))
    }

}

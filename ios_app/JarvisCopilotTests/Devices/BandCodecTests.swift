import XCTest
@testable import JarvisCopilot

/// The E910 band's codecs against the vendor's WeChat JS SDK run offline as an oracle. Requests:
/// the bytes the SDK wrote for the same call under a fixed clock (TZ=UTC unless noted). Replies:
/// real frames from the band (live_log, 2026-10-04) or frames whose SDK parse is quoted beside
/// the assertion. Each test names the SDK result it mirrors.
final class BandCodecTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    /// Hex as the oracle prints it; frames shorter than 20 bytes are zero-padded like parse.js does.
    private func bytes(_ hex: String, pad: Bool = true) -> [UInt8] {
        let clean = hex.replacingOccurrences(of: " ", with: "")
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            out.append(UInt8(clean[i..<j], radix: 16)!)
            i = j
        }
        if pad, out.count < 20 { out += [UInt8](repeating: 0, count: 20 - out.count) }
        return out
    }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // Real frames the band sent during the handshake (live_log.jsonl).
    private let featureFrames = ["a701000202020100061401020000000100060301", "a700030400030000030005010004020b05000102",
                                 "a702000100000105010000000100000401020203", "a702010000000000000000000001000000000004",
                                 "a700000001000001000000000000000000000005"]
    private let alertFrames = ["ad02010202020002020002020202020202000002", "ad02020202020002000000000000000000000010"]
    private let settingFrames = ["b802010101010000000002020200000002000000", "b802000002010002000201020101000000000001"]
    private let handshakeReply = "a10000060a99000702000001e73dc6402bea0000"

    private var realSettings: BandSettings { BandDecode.settings(settingFrames.map { bytes($0) })! }
    private var realAlerts: BandAlertSwitches { BandDecode.alerts(alertFrames.map { bytes($0) })! }

    // MARK: Requests (fixed.js / run.js TX)

    func testSessionRequests() {
        // veepooBlePasswordCheckManager @ 2026-10-04 19:11:49, TZ=UTC.
        XCTAssertEqual(hex(BandRequest.password(at: date(2026, 10, 4, 19, 11, 49), calendar: utc)),
                       "a100000007ea0a04130b31000100000000000000")
        // Same call under TZ=America/New_York (EDT): the last byte is −16 quarter hours.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(hex(BandRequest.password(at: date(2026, 10, 4, 19, 11, 49, calendar: ny), calendar: ny)),
                       "a100000007ea0a04130b310001f0000000000000")
        // veepooReadElectricQuantityManager / veepooSendGetProductInfoManager.
        XCTAssertEqual(hex(BandRequest.battery()), "a000000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.productInfo()), "fc00000000000000000000000000000000000000")
        // veepooSendSyncTimeManager 2026-10-04 14:30:05, format 2 (24 h) and 1 (12 h).
        XCTAssertEqual(hex(BandRequest.syncTime(date(2026, 10, 4, 14, 30, 5), hour24: true, calendar: utc)),
                       "a507ea0a040e1e05020000000000000000000000")
        XCTAssertEqual(hex(BandRequest.syncTime(date(2026, 10, 4, 14, 30, 5), hour24: false, calendar: utc)),
                       "a507ea0a040e1e05010000000000000000000000")
        // veepooSynchronizingPersonalInformationManager 178 cm 75 kg 25 y male 8000 steps 480 min.
        XCTAssertEqual(hex(BandRequest.profile(heightCm: 178, weightKg: 75, age: 25, male: true, stepGoal: 8000,
                                               sleepGoalMinutes: 480)),
                       "a3b24b19011f4001e00000000000000000000000")
    }

    func testHistoryRequests() {
        // veepooSendReadDailyDataManager {day 0, package 1} / {day 2, package 5}.
        XCTAssertEqual(hex(BandRequest.readDaily(day: 0, package: 1)), "df02000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readDaily(day: 2, package: 5)), "df06000200000000000000000000000000000000")
        // veepooSendReadPreciseSleepManager {day 1}.
        XCTAssertEqual(hex(BandRequest.readSleep(day: 1)), "e001000000000000000000000000000000000000")
        // veepooReadStepCalorieDistanceManager / veepooReadStepNumberManager {day 0}.
        XCTAssertEqual(hex(BandRequest.readSteps()), "d800000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readStepCount()), "a800000000000000000000000000000000000000")
        // veepooSendReadMovementPatternD4DataManager {module 1} / {module 3}; ...D3DataManager.
        XCTAssertEqual(hex(BandRequest.readSportRecords(module: 1)), "d400000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readSportRecords(module: 3)), "d402000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readSportCRCs()), "d301000000000000000000000000000000000000")
    }

    func testMeasurementRequests() {
        // In order: HeartRateTestSwitch, ReadUniversalBloodPressure, BloodOxygenControl,
        // TemperatureMeasurementSwitch, PressureTest, BloodGlucoseMeasurement, BloodComponent,
        // BodyCompositionTestStart/Stop, ECGmeasureStart/Stop — on, then off.
        let expected: [BandMeasure: (String, String)] = [
            .heartRate: ("d001", "d000"), .bloodPressure: ("900100", "900000"), .bloodOxygen: ("800100", "800200"),
            .temperature: ("870101", "870102"), .stress: ("890601", "890602"), .bloodGlucose: ("89010100", "89010200"),
            .bloodComponent: ("8a010100", "8a010200"), .bodyComposition: ("930401", "930402"),
            .ecg: ("9301010100", "9301020100"),
        ]
        for measure in BandMeasure.allCases {
            let (on, off) = expected[measure]!
            XCTAssertEqual(BandRequest.measure(measure, on: true), bytes(on), measure.name)
            XCTAssertEqual(BandRequest.measure(measure, on: false), bytes(off), measure.name)
        }
        XCTAssertEqual(BandMeasure(name: "spo2"), .bloodOxygen)
        XCTAssertEqual(BandMeasure.spo2, .bloodOxygen)
    }

    func testSportAndControlRequests() {
        // veepooSendSportControlDataManager setup mode 0 op 1 / op 4, then read mode 0.
        XCTAssertEqual(hex(BandRequest.sport(.start)), "da01000001000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.sport(.stop)), "da01000004000000000000000000000000000000")
        XCTAssertEqual(BandRequest.sport(.pause), bytes("da01000002"))   // live_log TX
        XCTAssertEqual(BandRequest.sport(.resume), bytes("da01000003"))  // live_log TX
        XCTAssertEqual(hex(BandRequest.sportStatus()), "da02000002000000000000000000000000000000")
        // veepooSendPhoneLookBraceletDataManager start / stop.
        XCTAssertEqual(hex(BandRequest.find(on: true)), "b50a000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.find(on: false)), "b50b000000000000000000000000000000000000")
        // veepooSendTakeAPictureDataManager start / stop; ResettingTheDevice; ResetData.
        XCTAssertEqual(hex(BandRequest.camera(true)), "b601000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.camera(false)), "b600000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.clearData()), "f180000000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.reboot()), "ff55017340000000000000000000000000000000")
    }

    func testReminderRequests() {
        // veepooSendSetupSedentaryToastTimeDataManager start 09:00–18:30 every 60; read.
        let sedentary = BandSedentary(enabled: true, intervalMinutes: 60, startHour: 9, startMinute: 0, endHour: 18, endMinute: 30)
        XCTAssertEqual(hex(BandRequest.sedentary(sedentary)), "e10900121e3c0100000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readSedentary()), "e100000000000200000000000000000000000000")
        // veepooSendHeartRateAlarmIntervalDataManager start / stop 150–45; read.
        XCTAssertEqual(hex(BandRequest.heartRateAlarm(enabled: true, high: 150, low: 45)), "ac962d0100000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.heartRateAlarm(enabled: false, high: 150, low: 45)), "ac962d0000000000000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readHeartRateAlarm()), "ac00000200000000000000000000000000000000")
        // veepooSendTurnWristBrightScreenDataManger start / stop 08:00–22:00 level 5; read.
        XCTAssertEqual(hex(BandRequest.raiseToWake(true)), "aa01080016000500000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.raiseToWake(false)), "aa00080016000500000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readRaiseToWake()), "aa02000000000000000000000000000000000000")
        // veepooSendBloodOxygenAutoTestDataManager start setup 22:00–07:00; ReadB3AutoTestFeatureData.
        XCTAssertEqual(hex(BandRequest.bloodOxygenAuto(enabled: true, start: (22, 0), end: (7, 0))),
                       "b300001600070001000000000000000000000000")
        XCTAssertEqual(hex(BandRequest.readBloodOxygenAuto()), "b302000000000000000000000000000000000000")
    }

    func testAlarmRequestsCarryTheSDKsCRC() {
        XCTAssertEqual(hex(BandRequest.readAlarms()), "b903000000000000000000000000000000000000")
        // veepooSendSetAlarmClockDataManager, four alarms (the CRC covers the record as the SDK's
        // hex string, so the day mask, label and id all move it).
        let weekdays = BandAlarm(id: 1, hour: 7, minute: 30, days: [.mon, .tue, .wed, .thu, .fri], enabled: true)
        XCTAssertEqual(hex(BandRequest.setAlarm(weekdays)), "b9020101a002180ba10cb10801011f071e300000b200")
        let gym = BandAlarm(id: 2, hour: 9, minute: 5, days: [.sat, .sun], enabled: false, label: "Gym")
        XCTAssertEqual(hex(BandRequest.setAlarm(gym)), "b9020101a002dffea10fb1080200600905300000b20347796d")
        let run = BandAlarm(id: 3, hour: 6, minute: 45, days: [.mon], enabled: true, label: "Run")
        XCTAssertEqual(hex(BandRequest.setAlarm(run)), "b9020101a0029190a10fb108030101062d300000b20352756e")
        let pills = BandAlarm(id: 4, hour: 23, minute: 59, days: [], enabled: true, label: "Pills ✓")
        XCTAssertEqual(hex(BandRequest.setAlarm(pills)), "b9020101a00252bfa115b108040100173b300000b20950696c6c7320e29c93")
        // veepooSendDeleteAlarmClockDataManager for the first two.
        XCTAssertEqual(hex(BandRequest.deleteAlarm(weekdays)), "b9010101a002e804a10cb10801011f071e000000b200")
        XCTAssertEqual(hex(BandRequest.deleteAlarm(gym)), "b9010101a0029f0fa10fb1080200600905000000b20347796d")
    }

    func testEveryOtherRequestIsOneFrame() {
        let frames: [[UInt8]] = [
            BandRequest.password(at: Date(), calendar: utc), BandRequest.battery(), BandRequest.productInfo(),
            BandRequest.syncTime(Date(), hour24: true, calendar: utc), BandRequest.readSettings(),
            BandRequest.writeSettings(realSettings), BandRequest.readDaily(day: 1, package: 1), BandRequest.readSleep(day: 0),
            BandRequest.readSportRecords(module: 2), BandRequest.sport(.start), BandRequest.find(on: true),
            BandRequest.readAlarms(), BandRequest.readSedentary(), BandRequest.alerts(realAlerts), BandRequest.readAlerts(),
            BandRequest.skinTone(3), BandRequest.camera(true), BandRequest.clearData(), BandRequest.readSteps(),
        ] + BandMeasure.allCases.map { BandRequest.measure($0, on: true) } + BandRequest.alertsFrames(realAlerts)
        for f in frames { XCTAssertEqual(f.count, 20, hex(f)) }
    }

    // MARK: Settings and alerts writes (SDK writes the stored frame back with byte 1 = 01)

    func testSettingsWritesMatchTheSDK() {
        let base = realSettings
        XCTAssertEqual(hex(BandRequest.readSettings()), "b802000000000000000000000000000000000000")
        // veepooSendUnitSettingDataManager {english, fahrenheit, mmol/L, μmol/L, mmol/L}.
        let imperial = BandSettings(json: ["units": "imperial", "temperature_unit": "f"], base: base)!
        XCTAssertEqual(BandRequest.writeSettingsFrames(imperial).map(hex),
                       ["b801020101010000000002020200000002000000", "b801000002020002000201020101000000000001"])
        // veepooSendAutoTestSwitchDataManager, one switch at a time.
        let cases: [(String, Bool, String, Bool)] = [
            ("auto_heart_rate", false, "b801010102010000000002020200000002000000", true),
            ("auto_hrv", true, "b801010101010000000002020100000002000000", true),
            ("low_spo2_alert", true, "b801010101010000000001020200000002000000", true),
            ("auto_temperature", true, "b801000001010002000201020101000000000001", false),
            ("auto_stress", true, "b801000002010002000101020101000000000001", false),
            ("auto_blood_glucose", true, "b801000002010001000201020101000000000001", false),
        ]
        for (name, on, expected, page1) in cases {
            let s = BandSettings(json: [name: on], base: base)!
            XCTAssertEqual(page1 ? hex(BandRequest.writeSettings(s)) : hex(BandRequest.writeSettingsPage2(s)!), expected, name)
        }
        // veepooSendSkinToneSettingDataManager {skinColorType 2, level 4}.
        XCTAssertEqual(hex(BandRequest.skinTone(4, settings: base)), "b801010101010000000002040200000002000000")
        XCTAssertEqual(BandRequest.skinTone(4), BandRequest.skinTone(4, settings: base))
        // A switch the band lacks stays absent, and a wrong type fails.
        XCTAssertEqual(BandSettings(json: ["music_control": true], base: base), base)
        XCTAssertNil(BandSettings(json: ["hour24": "yes"], base: base))
    }

    func testAlertWritesMatchTheSDK() {
        // veepooSendANCSSwitchControlDataManager with SMS, WhatsApp, Gmail, Telegram and Messenger
        // turned on over the band's real switches (Sina/Flickr/DingTalk/WeChat Work/JingYou absent).
        let on = BandAlertSwitches(json: ["messages": true, "apps": ["whatsapp": true, "gmail": true, "telegram": true,
                                                                       "messenger": true, "dingtalk": true]],
                                   base: realAlerts)!
        XCTAssertEqual(BandRequest.alertsFrames(on).map(hex),
                       ["ad01010102020002020002010202020201000002", "ad01020102020001000000000000000000000010"])
        XCTAssertEqual(BandRequest.alerts(on), BandRequest.alertsFrames(on)[0])
        XCTAssertNil(BandAlertSwitches(json: ["apps": ["whatsapp": 1]], base: realAlerts))
    }

    // MARK: Session replies (real frames)

    func testHandshake() {
        // SDK: {VPDeviceAck successfulVerification, VPDeviceVersion "00.07.02.00-2713",
        // VPDeviceRaiseHand open, VPDeviceMAC "EA:2B:40:C6:3D:E7", FindPhone/WearFlag noThisFeature}.
        let h = BandDecode.password(bytes(handshakeReply))!
        XCTAssertTrue(h.ok)
        XCTAssertEqual(h.ack, 6)
        XCTAssertEqual(h.firmware, "00.07.02.00-2713")
        XCTAssertEqual(h.deviceId, 2713)
        XCTAssertEqual(h.mac, "EA:2B:40:C6:3D:E7")
        XCTAssertEqual(h.raiseToWake, true)
        XCTAssertNil(h.findPhone)
        XCTAssertNil(h.wearDetection)
        XCTAssertEqual(h.json["firmware"] as? String, "00.07.02.00-2713")
        XCTAssertFalse(BandDecode.password(bytes("a1000000")).map(\.ok) ?? true)
    }

    func testFeatureTables() {
        // SDK 手环功能汇总 packages 1–4 (package 5 has no parser).
        let f = BandDecode.features(featureFrames.map { bytes($0) })
        XCTAssertEqual(f.types["bloodPressureType"], 1)
        XCTAssertEqual(f.types["bloodOxygenType"], 6)
        XCTAssertEqual(f.types["tipPackType"], 20)
        XCTAssertEqual(f.types["alarmClockType"], 6)
        XCTAssertEqual(f.types["heartRateFunctionType"], 3)
        XCTAssertEqual(f.types["dailyDataReadDayType"], 3)
        XCTAssertEqual(f.types["informationPushType"], 4)
        XCTAssertEqual(f.types["modeOfMotionStorageNumberType"], 3)
        XCTAssertEqual(f.types["HRVType"], 3)
        XCTAssertEqual(f.types["ECGFunction"], 11)
        XCTAssertEqual(f.types["motionModeType"], 5)
        XCTAssertEqual(f.types["bodyTemperatureFunctionType"], 5)
        XCTAssertEqual(f.types["lookupFunctionType"], 1)
        XCTAssertEqual(f.types["bloodComponentType"], 2)
        XCTAssertEqual(f.types["DAMotionContrlType"], 1)
        XCTAssertEqual(f.types["worldClockType"], 0)
        XCTAssertEqual(f.packages.count, 5)
        for name in ["heart_rate", "ecg", "hrv", "spo2", "blood_pressure", "temperature", "sport_control", "alarms", "find",
                     "camera", "blood_component", "body_composition", "skin_tone", "phone_alerts"] {
            XCTAssertTrue(f.supports(name), name)
        }
        XCTAssertFalse(f.supports("worldClockType"))
        XCTAssertFalse(f.supports("microCheckType"))
        XCTAssertTrue(f.supports("ECGFunction"))
        XCTAssertTrue((f.json["supported"] as? [String])?.contains("ecg") ?? false)
    }

    func testBattery() {
        // Real: SDK {charging, IsPercent true, 100, normal}.
        let real = BandDecode.battery(bytes("a001000064016401181100000000000000000000"))!
        XCTAssertEqual(real.percent, 100)
        XCTAssertTrue(real.charging)
        XCTAssertEqual(real.ring, RingBattery(percent: 100, charging: true))
        // SDK {normal, 50} / {lowPressure, 5} / {fullyCharged, 100}.
        XCTAssertEqual(BandDecode.battery(bytes("a000000032013201"))?.ring, RingBattery(percent: 50, charging: false))
        XCTAssertEqual(BandDecode.battery(bytes("a002000005010501"))?.low, true)
        let full = BandDecode.battery(bytes("a003000064016401"))!
        XCTAssertTrue(full.full)
        XCTAssertTrue(full.ring.charging)
    }

    func testProductInfo() {
        // Real three frames; SDK {productModule "3730314a", hardwareVersion 16, firmwareVersion
        // "00.02", productTPVersion "00.00.00.00.00.00"}.
        let frames = ["fc56504a31303710020019081c584d441a010101", "fc00000001000000000000000000000000000201",
                      "fc4a313037000000000000000000000000000301"].map { bytes($0) }
        XCTAssertNil(BandDecode.product(Array(frames.prefix(2))))
        let p = BandDecode.product(frames)!
        XCTAssertEqual(p.module, "3730314a")
        XCTAssertEqual(p.moduleName, "J107")
        XCTAssertEqual(p.hardwareVersion, 16)
        XCTAssertEqual(p.firmwareVersion, "00.02")
        XCTAssertEqual(p.touchPanelVersion, "00.00.00.00.00.00")
    }

    func testSettingsRead() {
        // Real: SDK package 0 {metricSystem, 24, autoHR open, autoBP open, OxygenLowerRemind close,
        // LedGrade 2, autoHRV close, autoPPG close, MusicControl noThisFeature}; package 1
        // {autoTemperature close, degreeCelsius, autoBloodGlucose close, Pressure close,
        // autoBloodComp close, FallWarning noThisFeature}.
        let s = realSettings
        XCTAssertEqual(s.metric, true)
        XCTAssertTrue(s.hour24)
        XCTAssertEqual(s.isOn("auto_heart_rate"), true)
        XCTAssertEqual(s.isOn("auto_blood_pressure"), true)
        XCTAssertEqual(s.isOn("low_spo2_alert"), false)
        XCTAssertEqual(s.skinTone, 2)
        XCTAssertEqual(s.isOn("auto_hrv"), false)
        XCTAssertEqual(s.isOn("auto_ppg"), false)
        XCTAssertNil(s.isOn("music_control"))
        XCTAssertEqual(s.isOn("auto_temperature"), false)
        XCTAssertEqual(s.celsius, true)
        XCTAssertEqual(s.isOn("auto_blood_glucose"), false)
        XCTAssertEqual(s.isOn("auto_stress"), false)
        XCTAssertEqual(s.isOn("auto_blood_component"), false)
        XCTAssertNil(s.isOn("fall_warning"))
        XCTAssertEqual(s, BandSettings.e910Default)
        XCTAssertEqual(s.json["units"] as? String, "metric")
        XCTAssertNil(s.json["music_control"])
        // SDK {settingStatus true} for the write ack.
        XCTAssertEqual(BandDecode.ack(bytes("b80101")), true)
    }

    func testAlertsRead() {
        // Real: SDK {Call start, SMS stop, Sina/Flickr/DingTalk/WeChatWork noThisFeature, the
        // rest stop; TikTok … Messenger stop, JingYou noThisFeature}.
        let a = realAlerts
        XCTAssertEqual(a.isOn("calls"), true)
        XCTAssertEqual(a.isOn("sms"), false)
        XCTAssertNil(a.isOn("sina"))
        XCTAssertNil(a.isOn("dingtalk"))
        XCTAssertEqual(a.isOn("whatsapp"), false)
        XCTAssertEqual(a.isOn("others"), false)
        XCTAssertEqual(a.isOn("telegram"), false)
        XCTAssertNil(a.isOn("jingyou"))
        XCTAssertEqual(a.json["calls"] as? Bool, true)
        XCTAssertEqual(a.json["messages"] as? Bool, false)
        XCTAssertEqual((a.json["apps"] as? [String: Bool])?["messenger"], false)
        XCTAssertNil((a.json["apps"] as? [String: Bool])?["sina"])
    }

    func testAcks() {
        // Real: 同步手环时间 设置成功, 同步个人信息 settingState true, 运动控制 success / failure.
        XCTAssertEqual(BandDecode.ack(bytes("a501000000000000000000000000000000000000")), true)
        XCTAssertEqual(BandDecode.ack(bytes("a301000000000000000000000000000000000000")), true)
        XCTAssertEqual(BandDecode.ack(bytes("a300")), false)
        XCTAssertEqual(BandDecode.sportAck(bytes("da0101", pad: false)), true)
        XCTAssertEqual(BandDecode.sportAck(bytes("da0100", pad: false)), false)
        // SDK 恢复出厂设置 Success.
        XCTAssertEqual(BandDecode.ack(bytes("f10001")), true)
    }

    // MARK: Measurements

    func testHeartRateStream() {
        let t = date(2026, 10, 4, 12, 0)
        // Real start reply: SDK {heartRate 1, deviceBusy false, notWear true}.
        let first = BandDecode.measurement(bytes("d0010000fd000000000000000000000000000000"), at: t)!
        XCTAssertEqual(first.measure, .heartRate)
        XCTAssertTrue(first.notWorn)
        XCTAssertNil(first.heartRate)
        // Real stop reply: SDK {heartRate 0, …false} — no value yet.
        let stop = BandDecode.measurement(bytes("d000000000000000000000000000000000000000"), at: t)!
        XCTAssertEqual(stop.status, .measuring)
        // The stream: SDK {heartRate 72, heartState 1, watchState 0, deviceBusy false, notWear false}.
        let beat = BandDecode.measurement(bytes("d048010000"), at: t)!
        XCTAssertEqual(beat.heartRate, 72)
        XCTAssertTrue(beat.finished)
        XCTAssertEqual(beat.date, t)
        XCTAssertEqual(beat.json["heart_rate"] as? Int, 72)
        XCTAssertEqual(beat.json["status"] as? String, "done")
        XCTAssertEqual(beat.json["type"] as? String, "heart_rate")
        // SDK {heartRate 72, watchState 253, deviceBusy true}: busy wins.
        XCTAssertTrue(BandDecode.measurement(bytes("d048010000fd"), at: t)!.busy)
        // SDK heartState 4 is not busy and still a value.
        XCTAssertEqual(BandDecode.measurement(bytes("d0480400000003"), at: t)?.heartRate, 72)
    }

    func testSpotMeasurements() {
        // Real SpO₂ start reply: SDK {bloodOxygen 0, deviceBusy true, notWear false}.
        XCTAssertTrue(BandDecode.measurement(bytes("8001ff0000000000000000000000000000000000"))!.busy)
        // SDK {bloodOxygen 97} / {bloodOxygen 1, notWear true}.
        XCTAssertEqual(BandDecode.measurement(bytes("80010061"))?.spo2, 97)
        XCTAssertTrue(BandDecode.measurement(bytes("80010001"))!.notWorn)
        // Blood pressure: SDK {Progress 100, state 0, high 118, low 82} / {error 测量失败} / {Progress 10}.
        let bp = BandDecode.measurement(bytes("9076526400010001"))!
        XCTAssertEqual(bp.systolic, 118)
        XCTAssertEqual(bp.diastolic, 82)
        XCTAssertTrue(bp.finished)
        XCTAssertEqual(BandDecode.measurement(bytes("901e146400010001"))?.status, .failed)
        let part = BandDecode.measurement(bytes("9076520a0001"))!
        XCTAssertEqual(part.progress, 10)
        XCTAssertEqual(part.status, .measuring)
        // Temperature: SDK {progress 100, bodyTemperature "36.1", bodySurfaceTemperature "35.5"},
        // {deviceDetectionInfo beMeasuringHeartRate}, {progress 50}.
        let temp = BandDecode.measurement(bytes("870101006469016301"))!
        XCTAssertEqual(temp.temperatureC ?? 0, 36.1, accuracy: 0.001)
        XCTAssertEqual(temp.surfaceTemperatureC ?? 0, 35.5, accuracy: 0.001)
        XCTAssertTrue(BandDecode.measurement(bytes("8701010264"))!.busy)
        XCTAssertEqual(BandDecode.measurement(bytes("8701010032"))?.progress, 50)
        // Stress: SDK {progress 100, pressure 60} / {progress 75} / {ack 1}.
        XCTAssertEqual(BandDecode.measurement(bytes("89060100643c"))?.stress, 60)
        XCTAssertEqual(BandDecode.measurement(bytes("890601004b"))?.status, .measuring)
        XCTAssertTrue(BandDecode.measurement(bytes("89060101"))!.busy)
        // Glucose: SDK {Progress 100, bloodGlucose 5.42} / {deviceAck notPassTheWearing}.
        XCTAssertEqual(BandDecode.measurement(bytes("89010100641e02"))?.bloodGlucose ?? 0, 5.42, accuracy: 0.0001)
        XCTAssertTrue(BandDecode.measurement(bytes("8901010400"))!.notWorn)
        // Blood component: SDK {uricAcidVal 50, cholesterol 2.78, triacylglycerol 2.68, highDensity
        // 1.21, lowDensity 0.84}.
        let blood = BandDecode.measurement(bytes("8a01010064f40116010c0179005400"))!.bloodComponent!
        XCTAssertEqual(blood, BandBloodComponent(uricAcid: 50, cholesterol: 2.78, triglycerides: 2.68, hdl: 1.21, ldl: 0.84))
    }

    func testSteps() {
        // SDK type 9 {step 1234, calorie 300, distance 1000, day today}; type 8 {stepNumber 4660}.
        XCTAssertEqual(BandDecode.steps(bytes("d800d2040000e80300002c010000")),
                       BandSteps(daysAgo: 0, steps: 1234, distanceMeters: 1000, calories: 300))
        XCTAssertEqual(BandDecode.steps(bytes("a8000012340000"))?.steps, 4660)
        XCTAssertNil(BandDecode.steps(bytes("a8ffffffff")))
    }

    // MARK: Sport control

    func testSportStatusAcrossFramesAndBandReports() {
        // Three frames under an A0 header; SDK {sportModel 0, opCode 1, runState Exercising,
        // exerciseTimeStamp 600, heartRate 146, deviceState Normal, exerciseDistance 800,
        // calories 100954} with Progress 33 → 67 → 100.
        let frames = ["da020101a0020301a1020000a20101a301010000", "da020102a0020302a50458020000a70192a40100",
                      "da020103a0020303a60420030000a8045a8a0100"].map { bytes($0) }
        let request = BandRequest.sportStatus()
        XCTAssertFalse(BandDecode.isComplete(Array(frames.prefix(2)), for: request))
        XCTAssertTrue(BandDecode.isComplete(frames, for: request))
        let s = BandDecode.sportStatus(frames)!
        XCTAssertEqual(s.sportMode, 0)
        XCTAssertEqual(s.opCode, 1)
        XCTAssertEqual(s.runState, .exercising)
        XCTAssertEqual(s.deviceState, .normal)
        XCTAssertEqual(s.elapsedSeconds, 600)
        XCTAssertEqual(s.distanceMeters, 800)
        XCTAssertEqual(s.heartRate, 146)
        XCTAssertEqual(s.calories, 100954)
        XCTAssertFalse(s.report)
        // One frame: SDK {opCode 2, runState Paused, deviceState Normal, heartRate 144}.
        let paused = BandDecode.sportStatus([bytes("da020101a1020000a20102a30102a40100a70190")])!
        XCTAssertEqual(paused.runState, .paused)
        XCTAssertEqual(paused.heartRate, 144)
        // The band's own report: SDK model deviceProactiveReport {sportModel 0, opCode 5, heartRate 136}.
        let report = BandDecode.sportStatus([bytes("da030101a1020000a20105a70188")])!
        XCTAssertTrue(report.report)
        XCTAssertEqual(report.opCode, 5)
        XCTAssertEqual(report.heartRate, 136)
    }

    // MARK: Controls

    func testFindCameraAndReminders() {
        // Real: SDK 开始查找 search / 停止查找 find.
        XCTAssertEqual(BandDecode.find(bytes("b50a010000000000000000000000000000000000")), true)
        XCTAssertEqual(BandDecode.find(bytes("b50b020000000000000000000000000000000000")), false)
        XCTAssertEqual(BandDecode.findEvent(bytes("b50a03")), .timeout)
        XCTAssertEqual(BandDecode.findEvent(bytes("b500")), .phoneWanted)
        // SDK 拍照 {Success, takePicture start} / {deviceCallTakePicture true}.
        XCTAssertEqual(BandDecode.camera(bytes("b6010200"))?.shutter, true)
        XCTAssertEqual(BandDecode.camera(bytes("b6010100"))?.shutter, false)
        XCTAssertEqual(BandDecode.camera(bytes("b6010001"))?.bandAsked, true)
        // SDK 久坐 {Success, switchStatus true, 09:00, 18:30, 60}; {noThisFeature}.
        XCTAssertEqual(BandDecode.sedentary(bytes("e1010900121e3c0101")),
                       BandSedentary(enabled: true, intervalMinutes: 60, startHour: 9, startMinute: 0, endHour: 18, endMinute: 30))
        XCTAssertNil(BandDecode.sedentary(bytes("e102")))
        // SDK 心率报警 {150, 45, state 1}; {error 操作失败}.
        XCTAssertEqual(BandDecode.heartRateAlarm(bytes("ac962d010201")), BandHeartRateAlarm(enabled: true, high: 150, low: 45))
        XCTAssertNil(BandDecode.heartRateAlarm(bytes("ac000000")))
        // SDK 抬手亮屏 {Success, 08:00–22:00, deviceSwitch start, level 5, read}.
        XCTAssertEqual(BandDecode.raiseToWake(bytes("aa0102080016000105")),
                       BandRaiseToWake(enabled: true, startHour: 8, startMinute: 0, endHour: 22, endMinute: 0, level: 5, defaultLevel: 0))
        // Real B3 read: SDK 血氧自动检测 {Success, stop, 00:00, 00:00}; set: {start, 22:00, 07:00}.
        XCTAssertEqual(BandDecode.bloodOxygenAuto(bytes("b301020000000000000000000000000000000000")),
                       BandOxygenSchedule(enabled: false, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0))
        XCTAssertEqual(BandDecode.bloodOxygenAuto(bytes("b30101001600070001"))?.enabled, true)
        // SDK 读取运动数据的CRC {CRC0 1000, CRC1 1, CRC2 2}.
        XCTAssertEqual(BandDecode.sportCRCs(bytes("d30101e80301000200")), [1000, 1, 2])
    }

    func testAlarms() {
        // Real empty read: SDK 读取文字闹钟 content [].
        XCTAssertEqual(BandDecode.alarms([bytes("b9030101a0030000000000000000000000000000")]), [])
        // A two-alarm read (one long notification); SDK content [{1, on, Mon–Fri, 07:30, null},
        // {2, off, Sat+Sun, 09:05, "Gym"}].
        let read = bytes("b9030101a0031234ffa10cb10801011f071e300000b200a10fb1080200600905300000b20347796d", pad: false)
        XCTAssertEqual(BandDecode.alarms([read]), [
            BandAlarm(id: 1, hour: 7, minute: 30, days: [.mon, .tue, .wed, .thu, .fri], enabled: true),
            BandAlarm(id: 2, hour: 9, minute: 5, days: [.sat, .sun], enabled: false, label: "Gym"),
        ])
        let alarm = BandAlarm(id: 2, hour: 9, minute: 5, days: [.sat, .sun], enabled: false, label: "Gym")
        XCTAssertEqual(alarm.json["time"] as? String, "09:05")
        XCTAssertEqual(alarm.json["days"] as? [String], ["sat", "sun"])
        XCTAssertEqual(BandAlarm(json: alarm.json), alarm)
        XCTAssertNil(BandAlarm(json: ["time": "25:00"]))
        XCTAssertNil(BandAlarm(json: ["time": "07:00", "days": ["funday"]]))
        let s = BandSedentary(enabled: true, intervalMinutes: 45, startHour: 8, startMinute: 30, endHour: 20, endMinute: 0)
        XCTAssertEqual(BandSedentary(json: s.json), s)
        XCTAssertEqual(BandSedentary(json: ["interval_minutes": 30], base: s)?.intervalMinutes, 30)
        XCTAssertNil(BandSedentary(json: ["start": "8"]))
    }

    // MARK: History

    func testDailyRecords() {
        let now = date(2026, 10, 4, 9, 0)
        // Real empty read: SDK {content [], Progress 100}.
        let empty = [bytes("dfffff0100000000000000000000000000000000")]
        XCTAssertEqual(BandDecode.daily(empty, day: 0, calendar: utc, now: now), [])
        XCTAssertTrue(BandDecode.isComplete(empty, for: BandRequest.readDaily(day: 0, package: 1)))
        // Two records over eight frames; SDK content [{currentPackageNum 102, date
        // "2026-10-04-08-30", step {420, 35, 310, 18500, wear 1}, pulseReat [72,74,0,78,80],
        // bloodPressure {118, 76}, bloodOxygen.oxygens [97,98,0,96,97], pressure [30,0,0,0,0],
        // bodyTemperature {36.2, surface 35.5}}, {103, "2026-10-04-08-35", step {0, 2, 0, 0, 0},
        // pulseReat [61,62,63,64,65]}].
        let frames = ["df01000008000409000000000014000000b1040a", "df02000104081eb20a01a40023013648440001b4",
                      "df030002050000000000b505484a004e50b80276", "df0400034cb9056162006061c1051e00000000c3",
                      "df0500040463016a010000000000000000000000", "df06000008000209000000000014000000b1040a",
                      "df070001040823b20a00000002000000000000b4", "df080002053d3e3f4041b5050000000000000000",
                      "dfffff0100000000000000000000000000000000"].map { bytes($0) }
        XCTAssertFalse(BandDecode.isComplete(Array(frames.dropLast()), for: BandRequest.readDaily(day: 0, package: 1)))
        let records = BandDecode.daily(frames, day: 0, calendar: utc, now: now)
        XCTAssertEqual(records.count, 2)
        let a = records[0]
        XCTAssertEqual(a.date, date(2026, 10, 4, 8, 30))
        XCTAssertEqual(a.slot, 102)
        XCTAssertEqual(a.steps, 420)
        XCTAssertEqual(a.exercise, 35)
        XCTAssertEqual(a.distanceMeters, 310)
        XCTAssertEqual(a.calories, 18500)
        XCTAssertEqual(a.worn, true)
        XCTAssertEqual(a.heartRates, [72, 74, 0, 78, 80])
        XCTAssertEqual(a.systolic, 118)
        XCTAssertEqual(a.diastolic, 76)
        XCTAssertEqual(a.spo2, [97, 98, 0, 96, 97])
        XCTAssertEqual(a.stress, [30, 0, 0, 0, 0])
        XCTAssertEqual(a.temperatureC ?? 0, 36.2, accuracy: 0.001)
        XCTAssertEqual(a.surfaceTemperatureC ?? 0, 35.5, accuracy: 0.001)
        let b = records[1]
        XCTAssertEqual(b.slot, 103)
        XCTAssertEqual(b.steps, 0)
        XCTAssertEqual(b.exercise, 2)
        XCTAssertEqual(b.heartRates, [61, 62, 63, 64, 65])
        XCTAssertNil(b.systolic)
    }

    func testDailyRecordWithHRVGlucoseAndBloodLipids() {
        // SDK {currentPackageNum 287, date "2026-10-03-23-55", step {12, 4, 9, 600, 1},
        // sleepData [1,2,3,0,0,0], pulseReat [58,57,56,0,55] (pulse all 0 → heart), respirationRate
        // [14,15,0,16,14], HRVData [23,28,0,0,0], bloodGlucose 5.42, meiTuo [9,10,11,0,0],
        // bloodLiquid {2.78, 2.68, 1.21, 0.84, uric 50}}.
        let frames = ["df01000009000809000000000014000000b1040a", "df020001031737b20a000c0004000902580001b4",
                      "df030002050000000000b5053a39380037b30601", "df0400030203000000b6050e0f00100eb7330050",
                      "df050004524f5150534e505251464b48004a4749", "df06000548464a00000000000000000000000000",
                      "df07000600000000000000000000000000000000", "df08000700be021e02bf05090a0b0000c20a1601",
                      "df0900080c0179005400f4010000000000000000", "dfffff0100000000000000000000000000000000"].map { bytes($0) }
        let r = BandDecode.daily(frames, day: 1, calendar: utc, now: date(2026, 10, 4, 9, 0)).first!
        XCTAssertEqual(r.date, date(2026, 10, 3, 23, 55))
        XCTAssertEqual(r.slot, 287)
        XCTAssertEqual(r.heartRates, [58, 57, 56, 0, 55])
        XCTAssertEqual(r.sleepStates, [1, 2, 3, 0, 0, 0])
        XCTAssertEqual(r.respiration, [14, 15, 0, 16, 14])
        XCTAssertEqual(r.hrv, [23, 28, 0, 0, 0])
        XCTAssertEqual(r.bloodGlucose ?? 0, 5.42, accuracy: 0.0001)
        XCTAssertEqual(r.met, [9, 10, 11, 0, 0])
        XCTAssertEqual(r.bloodComponent, BandBloodComponent(uricAcid: 50, cholesterol: 2.78, triglycerides: 2.68, hdl: 1.21, ldl: 0.84))
    }

    func testDecemberRecordsReadInJanuaryAreLastYear() {
        // The first record with month 12, read under a 2027-01-01 00:10 clock: SDK date "2026-12-04-08-30".
        let frames = ["df01000008000409000000000014000000b1040c", "df02000104081eb20a01a40023013648440001b4",
                      "df030002050000000000b505484a004e50b80276", "df0400034cb9056162006061c1051e00000000c3",
                      "df0500040463016a010000000000000000000000", "dfffff0100000000000000000000000000000000"].map { bytes($0) }
        let r = BandDecode.daily(frames, day: 0, calendar: utc, now: date(2027, 1, 1, 0, 10)).first
        XCTAssertEqual(r?.date, date(2026, 12, 4, 8, 30))
    }

    func testPreciseSleepTwoBitCurve() {
        let now = date(2026, 10, 4, 9, 0)
        // Real empty read: SDK {readDay yesterday, content {}}.
        XCTAssertEqual(BandDecode.sleep([bytes("e000000100000000000000000000000000000000")], calendar: utc, now: now), [])
        // One segment, curve type 2; SDK {fallAsleepTime "10-04-01-00", exitSleepTime "10-04-02-00",
        // nightScore 90, deepSleepScore 80, sleepEfficiencyScore 70, fallAsleepEfficiencyScore 60,
        // sleepTimeScore 50, sleepQuality 3, deep 15, light 35, other 5, total 60, firstDeep 15,
        // nightTotal 5, nightDeepMean 7, insomniaScore 88, insomniaCount 1, sleepCurve 10×1 15×0
        // 5×2 10×1 5×4 15×1}.
        let frames = ["e0030101a13e00a3220a0401000a040200005a50", "e0020101463c3200030000000f00230005003c00",
                      "e00101010f000500070002a403005801a53c0055", "e000010155500000002aa55555ffd55555550000"].map { bytes($0) }
        XCTAssertFalse(BandDecode.isComplete(Array(frames.prefix(3)), for: BandRequest.readSleep(day: 1)))
        XCTAssertTrue(BandDecode.isComplete(frames, for: BandRequest.readSleep(day: 1)))
        let s = BandDecode.sleep(frames, calendar: utc, now: now).first!
        XCTAssertEqual(s.start, date(2026, 10, 4, 1, 0))
        XCTAssertEqual(s.end, date(2026, 10, 4, 2, 0))
        XCTAssertEqual([s.nightScore, s.deepScore, s.efficiencyScore, s.fallAsleepScore, s.durationScore], [90, 80, 70, 60, 50])
        XCTAssertEqual(s.quality, 3)
        XCTAssertEqual([s.deepMinutes, s.lightMinutes, s.otherMinutes, s.totalMinutes], [15, 35, 5, 60])
        XCTAssertEqual([s.firstDeepMinutes, s.nightWakeMinutes, s.nightDeepMean], [15, 5, 7])
        XCTAssertEqual([s.insomniaScore, s.insomniaCount], [88, 1])
        XCTAssertEqual(s.sleepType, 2)
        let expected = [Int](repeating: 1, count: 10) + [Int](repeating: 0, count: 15) + [Int](repeating: 2, count: 5)
            + [Int](repeating: 1, count: 10) + [Int](repeating: 4, count: 5) + [Int](repeating: 1, count: 15)
        XCTAssertEqual(s.curve, expected)
        XCTAssertEqual(s.wakeCount, 1)
    }

    func testPreciseSleepTwoSegmentsThreeBitCurve() {
        // Two a1 blocks, curve type 1 (2 bytes a point); SDK content [{"10-03-23-10" →
        // "10-04-01-10", quality 2, total 120, insomniaScore 77, curve [1,1,0,0,0,2,1,4]},
        // {"10-04-02-00" → "10-04-06-30", quality 4, total 270, insomniaCount 2, curve [1,0,0,2,1,1]}].
        let frames = ["e0070200a13f00a3220a03170a0a04010a00463c", "e006020032281e00020000001e0050000a007800",
                      "e005020014000a00050001a403004d00a5100020", "e0040200002000000000000000400020008000a1",
                      "e00302003b00a3220a0402000a04061e0050555a", "e00202004b5800040000005a0096001e000e0128",
                      "e0010200000000090001a403005f02a50c002000", "e000020000000000400020002000000000000000"].map { bytes($0) }
        let nights = BandDecode.sleep(frames, calendar: utc, now: date(2026, 10, 4, 9, 0))
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].start, date(2026, 10, 3, 23, 10))
        XCTAssertEqual(nights[0].end, date(2026, 10, 4, 1, 10))
        XCTAssertEqual(nights[0].curve, [1, 1, 0, 0, 0, 2, 1, 4])
        XCTAssertEqual(nights[0].totalMinutes, 120)
        XCTAssertEqual(nights[0].insomniaScore, 77)
        XCTAssertEqual(nights[1].start, date(2026, 10, 4, 2, 0))
        XCTAssertEqual(nights[1].end, date(2026, 10, 4, 6, 30))
        XCTAssertEqual(nights[1].curve, [1, 0, 0, 2, 1, 1])
        XCTAssertEqual(nights[1].quality, 4)
        XCTAssertEqual(nights[1].insomniaCount, 2)
    }

    func testStoredWorkout() {
        // SDK 读取运动数据 Module 1 {head {startTime "2026-10-04-07-00-00", endTime
        // "2026-10-04-07-03-00", allStep 450, allDistance 320, allCalories 21000, allMovement 90,
        // recordCnt 3, pauseTimes 1, allPauseTime 30, crc 4660, sportType 1}, data [{110, 30, 150,
        // 7000, 100, 0}, {132, 35, 180, 8000, 120, 0}, {125, 25, 120, 6000, 100, 1}]}.
        let frames = ["d4010006000001ea070a04070000ea070a040703", "d4020006000000c201000040010000085200005a",
                      "d403000600000000000300011e00341201000000", "d404000600006e1e009600581b64000000000000",
                      "d40500060000842300b400401f78000000000000", "d406000600007d19007800701764000100000000"].map { bytes($0) }
        let request = BandRequest.readSportRecords(module: 1)
        XCTAssertFalse(BandDecode.isComplete(Array(frames.prefix(5)), for: request))
        XCTAssertTrue(BandDecode.isComplete(frames, for: request))
        let w = BandDecode.sportRecords(frames, calendar: utc).first!
        XCTAssertEqual(w.module, 1)
        XCTAssertEqual(w.start, date(2026, 10, 4, 7, 0))
        XCTAssertEqual(w.end, date(2026, 10, 4, 7, 3))
        XCTAssertEqual([w.steps, w.distanceMeters, w.calories, w.movement], [450, 320, 21000, 90])
        XCTAssertEqual([w.recordCount, w.pauseCount, w.pauseSeconds, w.crc, w.sportType], [3, 1, 30, 4660, 1])
        XCTAssertEqual(w.minutes, [
            BandSportMinute(heartRate: 110, movement: 30, steps: 150, calories: 7000, distanceMeters: 100, paused: false),
            BandSportMinute(heartRate: 132, movement: 35, steps: 180, calories: 8000, distanceMeters: 120, paused: false),
            BandSportMinute(heartRate: 125, movement: 25, steps: 120, calories: 6000, distanceMeters: 100, paused: true),
        ])
        XCTAssertEqual(w.json["heart_rate_max"] as? Int, 132)
        XCTAssertEqual(w.json["duration_s"] as? Int, 180)
    }

    // MARK: Framing

    func testHandshakeAndMultiPackageCompletion() {
        let request = BandRequest.password(at: Date(), calendar: utc)
        let tables = (featureFrames + alertFrames + settingFrames).map { bytes($0) }
        XCTAssertFalse(BandDecode.isComplete(tables, for: request))
        XCTAssertTrue(BandDecode.isComplete(tables + [bytes(handshakeReply)], for: request))
        XCTAssertTrue(tables.allSatisfy { BandOp.handshakeReplies.contains(BandDecode.opcode($0)) })
        // Settings: both packages; alerts: the package ending 00 10.
        XCTAssertFalse(BandDecode.isComplete([bytes(settingFrames[0])], for: BandRequest.readSettings()))
        XCTAssertTrue(BandDecode.isComplete(settingFrames.map { bytes($0) }, for: BandRequest.readSettings()))
        XCTAssertFalse(BandDecode.isComplete([bytes(alertFrames[0])], for: BandRequest.readAlerts()))
        XCTAssertTrue(BandDecode.isComplete(alertFrames.map { bytes($0) }, for: BandRequest.readAlerts()))
        // Single-frame replies: any frame with the request's opcode.
        XCTAssertTrue(BandDecode.isComplete([bytes("a001000064016401181100000000000000000000")], for: BandRequest.battery()))
        XCTAssertFalse(BandDecode.isComplete([bytes("d0010000fd")], for: BandRequest.battery()))
        XCTAssertTrue(BandOp.measurementReplies.contains(BandOp.heartRate))
        XCTAssertEqual(BandOp.dailyReplies, [0xDF])
        XCTAssertEqual(BandOp.sleepReplies, [0xE0])
    }
}

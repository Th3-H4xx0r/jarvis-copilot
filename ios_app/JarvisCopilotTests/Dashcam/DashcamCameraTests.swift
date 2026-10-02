import XCTest
@testable import JarvisCopilot

/// The camera layer: GPS blocks and lines (cross-checked against the Python reference parser),
/// Viidure/Novatek replies, and the client over a stubbed camera.
final class DashcamCameraTests: XCTestCase {
    override func setUp() { super.setUp(); DashcamStubProtocol.reset() }

    // MARK: GPS

    func testNormalBlockMatchesThePythonParser() throws {
        let block = DashcamSamples.normalBlock
        let tail = try XCTUnwrap(DashcamGPS.parseTail(block.suffix(8)))
        XCTAssertEqual(tail.marker, "&&&&")
        XCTAssertEqual(tail.size, block.count)
        let fixes = DashcamGPS.parseBlock(block, marker: tail.marker)
        XCTAssertEqual(fixes.count, 3)
        XCTAssertEqual(fixes[0].t, 1_790_869_200, accuracy: 0.01)
        XCTAssertEqual(fixes[0].lat, 41.8781, accuracy: 1e-4)
        XCTAssertEqual(fixes[0].lon, -87.6298, accuracy: 1e-4)
        XCTAssertEqual(fixes[0].speed ?? 0, 13.89, accuracy: 0.01)
        XCTAssertEqual(fixes[0].heading, 90)
        XCTAssertGreaterThan(fixes[2].lon, fixes[0].lon)
    }

    func testFHBlockVariant() {
        XCTAssertEqual(DashcamGPS.parseBlock(DashcamSamples.fhBlock, marker: "&&&&").count, 3)
    }

    func testLocalLineTimesAreAlignedToTheClip() {
        let fixes = DashcamGPS.parseBlock(DashcamSamples.normalBlock, marker: "&&&&")
        let aligned = DashcamGPS.align(fixes, clipStart: DashcamSamples.clipStart, duration: 60, tzOffset: DashcamSamples.tz)
        XCTAssertEqual(aligned[0].t, DashcamSamples.clipStart.timeIntervalSince1970, accuracy: 0.01)
        // Already-UTC lines are left alone.
        let utc = DashcamGPS.align(aligned, clipStart: DashcamSamples.clipStart, duration: 60, tzOffset: DashcamSamples.tz)
        XCTAssertEqual(utc[0].t, aligned[0].t)
    }

    func testJunkLinesAreDropped() {
        XCTAssertNil(DashcamGPS.parseLine("2026/10/01 20:00:00 N:- E:- - X:0 Y:0 Z:0 A:0 H:0"))
        XCTAssertNil(DashcamGPS.parseLine("2026/10/01 20:00:00 N:0000.0000 E:00000.0000 0 X:0 Y:0 Z:0 A:0 H:0"))
        XCTAssertNil(DashcamGPS.parseLine("garbage"))
        XCTAssertNil(DashcamGPS.parseTail(Data("xxxx\0\0\0\u{1}".utf8)))
        XCTAssertNil(DashcamGPS.parseTail(Data([0x26, 0x26, 0x26, 0x26, 0xff, 0xff, 0xff, 0xff])))   // absurd size
        XCTAssertTrue(DashcamGPS.parseBlock(Data(repeating: 0, count: 200), marker: "&&&&").isEmpty)
    }

    func testDecimalDegreesAndScrambledLines() throws {
        let d = try XCTUnwrap(DashcamGPS.parseLine("2026/10/01 20:00:00 N:41.878100 W:87.629800 72.0 X:0 Y:0 Z:1 A:180.0 H:3"))
        XCTAssertEqual(d.lat, 41.8781, accuracy: 1e-6)
        XCTAssertEqual(d.lon, -87.6298, accuracy: 1e-6)
        XCTAssertEqual(d.speed ?? 0, 20, accuracy: 1e-6)
        XCTAssertEqual(d.heading, 180)
        // `****` blocks scramble the coordinates and give knots (protocol.md §5).
        let latRaw = 4152.686, lonRaw = 8737.788
        let a10 = (latRaw / 10).rounded(.down) * 10, b10 = (lonRaw / 10).rounded(.down) * 10
        let a = a10 + (lonRaw - b10) * 0.8668, b = b10 + (latRaw - a10) * 0.8668
        let line = String(format: "2026/10/01 20:00:00 N:%.6f W:%.6f 20.0 X:0 Y:0 Z:1 A:10.0 H:5", a, b)
        let s = try XCTUnwrap(DashcamGPS.parseLine(line, scrambled: true))
        XCTAssertEqual(s.lat, 41.8781, accuracy: 1e-4)
        XCTAssertEqual(s.lon, -87.6298, accuracy: 1e-4)
        XCTAssertEqual(s.speed ?? 0, 20 * 1.852 / 3.6, accuracy: 0.01)
    }

    // MARK: Viidure replies

    func testViidureFileListParsing() {
        let info: [[String: Any]] = [
            ["folder": "loop", "count": 2, "files": [
                ["name": "/mnt/card/video_front/20261001_154000_F.mp4", "createtimestr": "20261001154000",
                 "size": 153600, "type": 2, "duration": 60],
                ["name": "/mnt/card/video_rear/20261001_154000_R.mp4", "createtime": 1_790_869_200,
                 "size": 76800, "type": 2, "duration": 60],
            ]],
            ["folder": "emr", "count": 1, "files": [
                ["name": "/mnt/card/emr/20261001_154100_F.mp4", "createtimestr": "20261001154100",
                 "size": 20000, "type": 2, "duration": 20, "GPSPATH": "/mnt/card/gps/x.txt"],
            ]],
            ["folder": "event", "count": 2, "files": [
                ["name": "/mnt/card/photo/20261001_154200_F.jpg", "createtimestr": "20261001154200", "size": 300, "type": 1],
                ["name": "/mnt/card/photo/empty.jpg", "createtimestr": "20261001154200", "size": 0, "type": 1],
            ]],
        ]
        let files = ViidureCamera.parseFileList(info, timeZone: DashcamSamples.zone)
        XCTAssertEqual(files.count, 4, "zero-size files are skipped")
        XCTAssertEqual(files[0].start, DashcamSamples.clipStart)
        XCTAssertEqual(files[0].lens, .front)
        XCTAssertEqual(files[0].size, 153600 * 1024)
        XCTAssertEqual(files[1].start, DashcamSamples.clipStart, "createtime is local wall clock")
        XCTAssertEqual(files[1].lens, .rear)
        XCTAssertEqual(files[2].kind, .event)
        XCTAssertTrue(files[2].locked)
        XCTAssertEqual(files[2].gpsPath, "/mnt/card/gps/x.txt")
        XCTAssertEqual(files[3].kind, .photo)
    }

    func testViidureEnvelopeErrorsCarryTheCameraMessage() {
        XCTAssertThrowsError(try ViidureCamera.unwrap(Data(#"{"result":-3,"info":"not in playback mode"}"#.utf8), cmd: "getfilelist")) {
            XCTAssertEqual($0 as? DashcamError, .camera("getfilelist: not in playback mode"))
        }
        XCTAssertThrowsError(try ViidureCamera.unwrap(Data("<html>".utf8), cmd: "x"))
    }

    func testSettingsMergeAndInfo() {
        let items: [[String: Any]] = [["name": "speed_unit", "index": ["0", "1"], "items": ["km/h", "mph"]],
                                      ["name": "ev", "range": "0-10"]]
        let values: [[String: Any]] = [["name": "speed_unit", "value": 1], ["name": "rec", "value": "1"]]
        let merged = ViidureCamera.mergeSettings(items: items, values: values)
        XCTAssertEqual(merged.first { $0.name == "speed_unit" }?.currentLabel, "mph")
        XCTAssertEqual(merged.first { $0.name == "ev" }?.range, "0-10")
        XCTAssertEqual(merged.first { $0.name == "rec" }?.value, "1")
        let info = ViidureCamera.parseInfo(attr: ["uuid": "", "imei": "", "bssid": "aa:bb", "softver": "V1", "camnum": 2],
                                           product: ["sp": "PEZTIO", "soc": "eeasytech", "model": "A4"],
                                           media: ["autorecord": 1])
        XCTAssertEqual(info.id, "aa:bb")
        XCTAssertEqual(info.lenses, 2)
        XCTAssertTrue(info.autorecord)
        XCTAssertEqual(info.brand, "PEZTIO")
    }

    // MARK: Novatek

    func testNovatekFileList() throws {
        let xml = """
        <?xml version="1.0"?><LIST><ALLFile>
        <File><NAME>a.MP4</NAME><FPATH>A:\\CARDV\\MOVIE\\2026_1001_154000_F.MP4</FPATH><SIZE>1000</SIZE><TIME>2026/10/01 15:40:00</TIME><ATTR>32</ATTR></File>
        <File><NAME>b.MP4</NAME><FPATH>A:\\CARDV\\MOVIE\\RO\\2026_1001_154100_R.MP4</FPATH><SIZE>500</SIZE><TIME>2026/10/01 15:41:00</TIME><ATTR>21</ATTR></File>
        <File><NAME>c.JPG</NAME><FPATH>A:\\CARDV\\PHOTO\\c.JPG</FPATH><SIZE>50</SIZE><TIME>2026/10/01 15:42:00</TIME><ATTR>32</ATTR></File>
        </ALLFile></LIST>
        """
        let files = NovatekCamera.parseFileList(try NovatekXML.parse(Data(xml.utf8)), timeZone: DashcamSamples.zone)
        XCTAssertEqual(files.map(\.path).first, "/CARDV/MOVIE/2026_1001_154000_F.MP4")
        XCTAssertEqual(files[0].start, DashcamSamples.clipStart)
        XCTAssertEqual(files[1].kind, .event)
        XCTAssertEqual(files[1].lens, .rear)
        XCTAssertEqual(files[2].kind, .photo)
    }

    // MARK: Client over a stubbed camera

    func testFilesPageThroughEveryFolder() async throws {
        func page(_ folder: String, _ n: Int, _ offset: Int) -> [[String: Any]] {
            [["folder": folder, "count": n, "files": (0..<n).map {
                ["name": "/mnt/card/\(folder)/\(offset + $0)_F.mp4", "createtimestr": "20261001154000",
                 "size": 10, "type": 2, "duration": 60]
            }]]
        }
        DashcamStubProtocol.on("folder=loop&start=0&") { _ in DashcamSamples.json(["result": 0, "info": page("loop", 100, 0)]) }
        DashcamStubProtocol.on("folder=loop&start=100&") { _ in DashcamSamples.json(["result": 0, "info": page("loop", 3, 100)]) }
        DashcamStubProtocol.on("folder=emr") { _ in DashcamSamples.json(["result": 0, "info": page("emr", 2, 0)]) }
        DashcamStubProtocol.on("getfilelist") { _ in DashcamSamples.json(["result": -1, "info": "empty"]) }
        let cam = ViidureCamera(http: DashcamHTTP(base: URL(string: "http://192.168.169.1")!, session: DashcamStubProtocol.session()))
        let files = try await cam.files(timeZone: DashcamSamples.zone)
        XCTAssertEqual(files.filter { $0.folder == "loop" }.count, 103)
        XCTAssertEqual(files.filter { $0.kind == .event }.count, 2)
    }

    func testPagingContinuesPastFilesItDropped() async throws {
        // 100 raw entries of which two are 0 KB (still being written): not the last page.
        var first: [[String: Any]] = (0..<98).map { ["name": "/mnt/card/loop/\($0).mp4", "createtimestr": "20261001154000", "size": 10, "type": 2] }
        first += [["name": "/mnt/card/loop/w1.mp4", "size": 0, "type": 2], ["name": "/mnt/card/loop/w2.mp4", "size": 0, "type": 2]]
        DashcamStubProtocol.on("folder=loop&start=0&") { _ in DashcamSamples.json(["result": 0, "info": [["folder": "loop", "files": first]]]) }
        DashcamStubProtocol.on("folder=loop&start=100&") { _ in
            DashcamSamples.json(["result": 0, "info": [["folder": "loop", "files": [["name": "/mnt/card/loop/x.mp4", "createtimestr": "20261001154000", "size": 10, "type": 2]]]]])
        }
        DashcamStubProtocol.on("getfilelist") { _ in DashcamSamples.json(["result": 0, "info": []]) }
        let cam = ViidureCamera(http: DashcamHTTP(base: URL(string: "http://192.168.169.1")!, session: DashcamStubProtocol.session()))
        let files = try await cam.files(timeZone: DashcamSamples.zone)
        XCTAssertEqual(files.count, 99)
    }

    func testListingRefusedEverywhereThrowsTheCameraMessage() async {
        DashcamStubProtocol.on("getfilelist") { _ in DashcamSamples.json(["result": -3, "info": "not in playback mode"]) }
        let cam = ViidureCamera(http: DashcamHTTP(base: URL(string: "http://192.168.169.1")!, session: DashcamStubProtocol.session()))
        do {
            _ = try await cam.files(timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTFail("expected the refusal to surface")
        } catch {
            XCTAssertEqual(error as? DashcamError, .camera("getfilelist?folder=race&start=0&end=99: not in playback mode"))
        }
    }

    func testGPSIsReadFromTheTailWithRangeRequests() async throws {
        var clip = Data(repeating: 7, count: 50_000)
        clip.append(DashcamSamples.normalBlock)
        DashcamStubProtocol.on("/mnt/card/video_front/a.mp4", DashcamSamples.ranged(clip))
        let cam = ViidureCamera(http: DashcamHTTP(base: URL(string: "http://192.168.169.1")!, session: DashcamStubProtocol.session()))
        let file = DashcamFile(path: "/mnt/card/video_front/a.mp4", kind: .normal, lens: .front,
                               start: DashcamSamples.clipStart, durationS: 60, size: Int64(clip.count))
        let fixes = try await cam.gps(file, tzOffset: DashcamSamples.tz)
        XCTAssertEqual(fixes.count, 3)
        XCTAssertEqual(fixes[0].t, DashcamSamples.clipStart.timeIntervalSince1970, accuracy: 0.01)
        let ranges = DashcamStubProtocol.requests().compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(ranges.count, 3, "size probe + tail + block — never the whole clip")
        XCTAssertTrue(ranges.allSatisfy { !$0.hasSuffix("-") })
    }

    func testDetectFindsAViidureCameraAtAPinnedHost() async {
        DashcamStubProtocol.on("/app/getdeviceattr") { _ in DashcamSamples.json(["result": 0, "info": ["uuid": "X"]]) }
        let found = await DashcamDetect.probe(host: "127.0.0.1:8099", timeout: 1, session: DashcamStubProtocol.session())
        XCTAssertEqual(found?.family, .viidure)
        XCTAssertEqual(found?.base.absoluteString, "http://127.0.0.1:8099")
    }
}

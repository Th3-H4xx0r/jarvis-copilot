import AVFoundation
import XCTest
@testable import JarvisCopilot

/// The A4's `.ts` clips → MP4 so AVPlayer can play them, plus the GPS that rides in the same stream.
final class DashcamRemuxTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ data: Data, _ name: String = "clip_f.ts") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertPlayable(_ url: URL, codec: CMVideoCodecType, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, file: file, line: line)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.25, file: file, line: line)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1, file: file, line: line)
        let formats = try await video[0].load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), codec, file: file, line: line)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90), file: file, line: line)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, file: file, line: line)
        // Frames really decode: a still from the middle of the clip.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, 160, file: file, line: line)
    }

    func testAnH264ClipBecomesAPlayableMP4WithItsGPS() async throws {
        let out = dir.appendingPathComponent("clip_f.mp4")
        let result = try await DashcamRemux.remux(ts: try clip(DashcamTSFixtures.h264), to: out)
        XCTAssertEqual(result.codec, "h264")
        XCTAssertTrue(result.hasAudio)
        XCTAssertEqual(result.duration, 2.0, accuracy: 0.25)
        XCTAssertEqual(result.fixes.count, 3)
        XCTAssertEqual(result.fixes[0].lat, 41 + 52.686 / 60, accuracy: 1e-6)
        XCTAssertEqual(result.fixes[0].lon, -(87 + 37.788 / 60), accuracy: 1e-6)
        XCTAssertEqual(result.fixes[0].speed ?? 0, 50 / 3.6, accuracy: 0.01)
        try await assertPlayable(out, codec: kCMVideoCodecType_H264)
    }

    func testAnHEVCClipBecomesAPlayableMP4() async throws {
        let out = dir.appendingPathComponent("clip_b.mp4")
        let result = try await DashcamRemux.remux(ts: try clip(DashcamTSFixtures.hevc, "clip_b.ts"), to: out)
        XCTAssertEqual(result.codec, "hevc")
        XCTAssertEqual(result.fixes.count, 3)
        try await assertPlayable(out, codec: kCMVideoCodecType_HEVC)
    }

    func testSmallReadChunksGiveTheSameFile() async throws {
        // Packets and PES units split across reads must reassemble.
        let out = dir.appendingPathComponent("chunked.mp4")
        let result = try await DashcamRemux.remux(ts: try clip(DashcamTSFixtures.h264), to: out, chunk: 1000)
        XCTAssertEqual(result.fixes.count, 3)
        XCTAssertTrue(result.hasAudio)
        try await assertPlayable(out, codec: kCMVideoCodecType_H264)
    }

    func testTheOutputAppearsOnlyWhenComplete() async throws {
        let out = dir.appendingPathComponent("clip_f.mp4")
        try Data("stale".utf8).write(to: out)
        _ = try await DashcamRemux.remux(ts: try clip(DashcamTSFixtures.h264), to: out)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") })
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
    }

    func testANonTransportStreamIsRefused() async throws {
        let junk = try clip(Data(repeating: 0x11, count: 4096), "junk.ts")
        do {
            _ = try await DashcamRemux.remux(ts: junk, to: dir.appendingPathComponent("junk.mp4"))
            XCTFail("expected a failure")
        } catch let failure as DashcamRemux.Failure {
            XCTAssertEqual(failure, .notTransportStream)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.mp4").path))
    }

    func testGPSComesOutOfAWindowThatStartsMidPacket() {
        // The camera path reads byte ranges, which needn't start on a packet boundary.
        let data = DashcamTSFixtures.h264
        XCTAssertEqual(DashcamRemux.gpsLines(in: data).count, 3)
        let window = data.subdata(in: 100..<data.count)
        let lines = DashcamRemux.gpsLines(in: window)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("2026/10/02 13:19:31 N:4152.6860"))
        XCTAssertEqual(DashcamRemux.gpsLines(in: Data(repeating: 0x47, count: 100)), [])
    }
    func testALocalClipsTailGPSIsReadWhenThePacketsHaveNone() async throws {
        // The real A4 layout: plain TS packets, then the GPS boxes appended after the last packet.
        var data = DashcamTSFixtures.h264.subdata(in: 0..<188)      // PAT only, no GPS packets
        data.append(DashcamCameraTests.a4SkipBlock([
            "2026/10/02 13:19:32 N:4152.6860 W:08737.7880 48.0 km/h x:+0.00 y:+0.00 z:+0.00 A:91.0 H:182.0 304A126B2FC86505BTRX"]))
        XCTAssertEqual(DashcamRemux.tailFixes(try clip(data, "tail.ts")).count, 1)
        // …and a full clip with junk after its packets still converts.
        var whole = DashcamTSFixtures.h264
        whole.append(DashcamCameraTests.a4SkipBlock(["2026/10/02 13:19:32 N:0 E:0 0.0 km/h A:0.0 H:0.0"], marker: "&&&&"))
        let result = try await DashcamRemux.remux(ts: try clip(whole, "whole.ts"), to: dir.appendingPathComponent("whole.mp4"))
        XCTAssertEqual(result.duration, 2.0, accuracy: 0.25)
    }

    func testPlayableCopiesAreCachedAndPruned() async throws {
        let cache = dir.appendingPathComponent("cache")
        let ts = try clip(DashcamTSFixtures.h264)
        let first = try await DashcamPlayable.prepare(ts, in: cache)
        XCTAssertNotNil(first.made)
        XCTAssertEqual(first.url.pathExtension, "mp4")
        let again = try await DashcamPlayable.prepare(ts, in: cache)
        XCTAssertEqual(again.url, first.url)
        XCTAssertNil(again.made)                                   // reused, not remade
        // An mp4 needs nothing.
        let mp4 = dir.appendingPathComponent("x.mp4")
        try Data().write(to: mp4)
        let direct = try await DashcamPlayable.prepare(mp4, in: cache)
        XCTAssertEqual(direct.url, mp4)
        // Only the newest `keep` copies stay.
        for i in 0..<(DashcamPlayable.keep + 3) {
            try Data("x".utf8).write(to: cache.appendingPathComponent("old\(i).mp4"))
        }
        DashcamPlayable.prune(cache, keeping: first.url)
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".mp4") }
        XCTAssertEqual(left.count, DashcamPlayable.keep)
        XCTAssertTrue(left.contains(first.url.lastPathComponent))
    }
}

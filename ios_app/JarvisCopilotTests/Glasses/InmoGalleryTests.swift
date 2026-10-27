import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class InmoGalleryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func photo(_ ms: Int64, size: Int = 100) -> InmoMediaItem {
        InmoMediaItem(name: "INMOIMG_\(ms).jpg", directory: "D:\\Photos", size: size)
    }
    private func video(_ ms: Int64) -> [InmoMediaItem] {
        ["mp4": 900, "opus": 40, "gcsv": 30].map { InmoMediaItem(name: "INMOVID_\(ms).\($0.key)", directory: "D:\\Video", size: $0.value) }
    }

    // MARK: Library model

    func testNamesGiveDatesAndKinds() throws {
        let grouped = InmoMediaGrouping.group([photo(1790453383660)])
        let item = try XCTUnwrap(grouped.gallery.first)
        XCTAssertEqual(item.kind, .photo)
        XCTAssertEqual(item.capturedAt.timeIntervalSince1970, 1790453383.660, accuracy: 0.001)
        XCTAssertEqual(item.picture?.name, "INMOIMG_1790453383660.jpg")
        XCTAssertNil(item.sound)
    }

    func testVideoPartsAreOneItem() throws {
        let grouped = InmoMediaGrouping.group(video(1790457871450))
        XCTAssertEqual(grouped.gallery.count, 1)
        XCTAssertTrue(grouped.other.isEmpty)
        let item = try XCTUnwrap(grouped.gallery.first)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.picture?.name, "INMOVID_1790457871450.mp4")
        XCTAssertEqual(item.sound?.name, "INMOVID_1790457871450.opus")
        XCTAssertEqual(item.parts.count, 3)
    }

    func testAudioAndUnknownGoToOther() {
        let grouped = InmoMediaGrouping.group([
            InmoMediaItem(name: "INMOAUD_1790455500803.opus", directory: "D:\\Audio", size: 5),
            InmoMediaItem(name: "notes.txt", directory: "D:\\Misc", size: 5),
            InmoMediaItem(name: "INMOVID_1.opus", directory: "D:\\Video", size: 5),
        ])
        XCTAssertTrue(grouped.gallery.isEmpty)
        XCTAssertEqual(grouped.other.count, 3)
    }

    func testRecordPersistsAcrossInstances() throws {
        let library = InmoMediaLibrary(directory: root)
        let item = try XCTUnwrap(InmoMediaGrouping.group([photo(1790453383660)]).gallery.first)
        try library.record(InmoGalleryRecord(key: item.key, kind: .photo, capturedAt: item.capturedAt,
                                             parts: ["INMOIMG_1790453383660.jpg": 100], savedAt: Date(), thumb: "a.jpg"))
        let again = InmoMediaLibrary(directory: root)
        XCTAssertTrue(again.isSaved(item.key))
        XCTAssertEqual(again.records[item.key]?.thumb, "a.jpg")
        XCTAssertEqual(again.records[item.key]?.parts, ["INMOIMG_1790453383660.jpg": 100])
    }

    func testSameNameNewSizeIsNewItem() {
        let a = InmoMediaGrouping.group([photo(5, size: 100)]).gallery.first?.key
        let b = InmoMediaGrouping.group([photo(5, size: 101)]).gallery.first?.key
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    func testMergeKeepsSavedItemsOffGlasses() throws {
        let live = InmoMediaGrouping.group([photo(2000)]).gallery
        let gone = InmoGalleryRecord(key: "INMOIMG_1000-100", kind: .photo, capturedAt: Date(timeIntervalSince1970: 1),
                                     parts: ["INMOIMG_1000.jpg": 100], savedAt: Date())
        let newer = InmoGalleryRecord(key: "INMOIMG_3000-100", kind: .photo, capturedAt: Date(timeIntervalSince1970: 3),
                                      parts: ["INMOIMG_3000.jpg": 100], savedAt: Date())
        let entries = InmoMediaLibrary.merge(live: live, records: [gone.key: gone, newer.key: newer])
        XCTAssertEqual(entries.map(\.key), ["INMOIMG_3000-100", "INMOIMG_2000-100", "INMOIMG_1000-100"])
        XCTAssertNil(entries[0].item)
        XCTAssertTrue(entries[0].saved)
        XCTAssertNotNil(entries[1].item)
        XCTAssertFalse(entries[1].saved)
    }

    // MARK: Sound and previews

    func testOpusSplitSkipsLeadingEmptyPieces() {
        let data = Data("\n\n\n\n\n\nAB\n\n\nC".utf8)
        XCTAssertEqual(InmoOpusFile.packets(data), [Data("AB".utf8), Data("C".utf8)])
        XCTAssertEqual(InmoOpusFile.packets(Data()), [])
    }

    func testUndecodablePacketsBecomeSilence() throws {
        let garbage = Data(repeating: 0xff, count: 2000) + Data(InmoOpusFile.separator) + Data(repeating: 0xff, count: 2000)
        let result = try InmoOpusFile.pcm(garbage)
        XCTAssertEqual(result.packets, 2)
        XCTAssertEqual(result.failed, 2)
        XCTAssertEqual(result.pcm.count, 1280)
    }

    func testMergeWithoutSoundFallsBackToPicture() async throws {
        let movie = try await makeMovie(seconds: 1)
        let opus = root.appendingPathComponent("bad.opus")
        try (Data(repeating: 0xff, count: 2000) + Data(InmoOpusFile.separator) + Data(repeating: 0xff, count: 2000)).write(to: opus)
        let output = root.appendingPathComponent("out.mp4")
        let withSound = await InmoVideoMerger.merge(video: movie, opus: opus, to: output)
        XCTAssertFalse(withSound)
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video).count
        let audioTracks = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(videoTracks, 1)
        XCTAssertEqual(audioTracks, 0)
        let none = await InmoVideoMerger.merge(video: movie, opus: nil, to: output)
        XCTAssertFalse(none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    /// The real files rebuilt from the private capture (never committed). Skipped without them.
    func testMergeRealFixture() async throws {
        let dir = ProcessInfo.processInfo.environment["JC_INMO_FIXTURES"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_JC_INMO_FIXTURES"] ?? ""
        let mp4 = URL(fileURLWithPath: dir).appendingPathComponent("INMOVID_1790457871450.mp4")
        let opus = URL(fileURLWithPath: dir).appendingPathComponent("INMOVID_1790457871450.opus")
        try XCTSkipUnless(!dir.isEmpty && FileManager.default.fileExists(atPath: mp4.path), "no JC_INMO_FIXTURES")
        let decoded = try InmoOpusFile.pcm(try Data(contentsOf: opus))
        XCTAssertGreaterThan(decoded.packets, 300)
        XCTAssertLessThan(decoded.failed, 10)
        let output = root.appendingPathComponent("merged.mp4")
        let withSound = await InmoVideoMerger.merge(video: mp4, opus: opus, to: output)
        XCTAssertTrue(withSound)
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let videoLength = try await asset.load(.duration).seconds
        let audioLength = try await audio[0].load(.timeRange).duration.seconds
        XCTAssertEqual(videoLength, 6.8, accuracy: 0.3)
        XCTAssertEqual(audioLength, Double(decoded.packets) * 0.02, accuracy: 0.2)   // 20 ms a packet
        XCTAssertLessThanOrEqual(audioLength, videoLength)
        if let keep = ProcessInfo.processInfo.environment["JC_INMO_KEEP"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: output, to: URL(fileURLWithPath: keep))
        }
    }

    func testThumbnailOfVideoAndPhoto() async throws {
        let movie = try await makeMovie(seconds: 1)
        let thumb = try await InmoMediaThumbnail.make(movie, kind: .video)
        XCTAssertFalse(thumb.jpeg.isEmpty)
        XCTAssertEqual(thumb.duration ?? 0, 1, accuracy: 0.15)
        let image = try XCTUnwrap(UIImage(data: thumb.jpeg))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, 400)

        let jpg = root.appendingPathComponent("p.jpg")
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
        try XCTUnwrap(big.jpegData(compressionQuality: 0.9)).write(to: jpg)
        let photoThumb = try await InmoMediaThumbnail.make(jpg, kind: .photo)
        let small = try XCTUnwrap(UIImage(data: photoThumb.jpeg))
        XCTAssertLessThanOrEqual(max(small.size.width, small.size.height) * small.scale, 400)
        XCTAssertNil(photoThumb.duration)
    }

    // MARK: Save & download all

    func testSaveAllSavesUnsavedPhotosFirstAndRecordsThem() async throws {
        let library = InmoMediaLibrary(directory: root)
        let done = try XCTUnwrap(InmoMediaGrouping.group([photo(1000)]).gallery.first)
        try library.record(InmoGalleryRecord(key: done.key, kind: .photo, capturedAt: done.capturedAt, parts: [:], savedAt: Date()))
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(1000), photo(3000)] + video(2000))
        let saver = GalleryFakeSaver()
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: library)
        XCTAssertEqual(gallery.unsaved.count, 2)

        await gallery.saveAll()

        XCTAssertEqual(saver.saved.map(\.name), ["INMOIMG_3000.jpg", "INMOVID_2000.mp4"])
        XCTAssertEqual(saver.saved.map(\.isPhoto), [true, false])
        XCTAssertEqual(fetcher.opens, 1)
        XCTAssertEqual(fetcher.closes, 1)
        XCTAssertEqual(fetcher.fetched, ["INMOIMG_3000.jpg", "INMOVID_2000.mp4", "INMOVID_2000.opus"])
        XCTAssertEqual(gallery.unsaved.count, 0)
        XCTAssertTrue(gallery.entries.allSatisfy(\.saved))
        // The fake video can't be merged: saved picture-only and flagged.
        XCTAssertEqual(library.records["INMOVID_2000-900"]?.withoutSound, true)
        XCTAssertEqual(library.records["INMOIMG_3000-100"]?.withoutSound, false)
        // Jarvis's copies are gone.
        XCTAssertTrue(fetcher.handedOut.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertNil(gallery.run)
        XCTAssertEqual(gallery.message, "Saved 2 to your camera roll. 1 video without sound.")
    }

    func testDeniedPhotosNeverOpensWiFi() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(1)])
        let saver = GalleryFakeSaver(); saver.allowed = false
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: InmoMediaLibrary(directory: root))
        await gallery.saveAll()
        XCTAssertEqual(fetcher.opens, 0)
        XCTAssertTrue(saver.saved.isEmpty)
        XCTAssertTrue(gallery.message?.contains("Photos") == true)
        XCTAssertEqual(gallery.unsaved.count, 1)
    }

    func testCancelMidBatchLeavesRestUnsavedAndClosesWiFi() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(2), photo(1)])
        let saver = GalleryFakeSaver()
        let library = InmoMediaLibrary(directory: root)
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: library)
        saver.onSave = { gallery.cancel() }
        await gallery.saveAll()
        XCTAssertEqual(saver.saved.count, 1)
        XCTAssertTrue(library.isSaved("INMOIMG_2-100"))     // it reached Photos, so it's recorded
        XCTAssertFalse(library.isSaved("INMOIMG_1-100"))
        XCTAssertEqual(fetcher.closes, 1)
        XCTAssertEqual(fetcher.cancels, 1)
        XCTAssertEqual(gallery.message, "Saved 1 to your camera roll. Cancelled — 1 not saved.")
    }

    func testCancelWhileAskingForPhotosNeverOpensWiFi() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(1)])
        let saver = GalleryFakeSaver()
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: InmoMediaLibrary(directory: root))
        saver.onAuthorize = { gallery.cancel() }
        await gallery.saveAll()
        XCTAssertEqual(fetcher.opens, 0)
        XCTAssertTrue(saver.saved.isEmpty)
        XCTAssertNil(gallery.run)
    }

    func testFetchFailureMarksFailedAndContinues() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(2), photo(1)])
        fetcher.failing = ["INMOIMG_2.jpg"]
        let saver = GalleryFakeSaver()
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: InmoMediaLibrary(directory: root))
        await gallery.saveAll()
        XCTAssertEqual(saver.saved.map(\.name), ["INMOIMG_1.jpg"])
        XCTAssertEqual(gallery.failed, ["INMOIMG_2-100"])
        XCTAssertEqual(gallery.unsaved.map(\.key), ["INMOIMG_2-100"])
        XCTAssertEqual(fetcher.closes, 1)
    }

    func testSaveFailureLeavesItemUnsaved() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(1)])
        let saver = GalleryFakeSaver(); saver.fail = true
        let library = InmoMediaLibrary(directory: root)
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: library)
        await gallery.saveAll()
        XCTAssertFalse(library.isSaved("INMOIMG_1-100"))
        XCTAssertTrue(fetcher.handedOut.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSaveAllRefusesWhileRunningOrNothingToSave() throws {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(1)])
        let gallery = InmoGallery(fetcher: fetcher, saver: GalleryFakeSaver(), library: InmoMediaLibrary(directory: root))
        XCTAssertEqual(try gallery.startSaveAll(), 1)
        XCTAssertThrowsError(try gallery.startSaveAll())
        let empty = InmoGallery(fetcher: GalleryFakeFetcher(root: root, inventory: []), saver: GalleryFakeSaver(), library: InmoMediaLibrary(directory: root))
        XCTAssertThrowsError(try empty.startSaveAll())
    }

    func testOnlyAskedKeysAreSaved() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(2), photo(1)])
        let saver = GalleryFakeSaver()
        let gallery = InmoGallery(fetcher: fetcher, saver: saver, library: InmoMediaLibrary(directory: root))
        await gallery.saveAll(keys: ["INMOIMG_1-100"])
        XCTAssertEqual(saver.saved.map(\.name), ["INMOIMG_1.jpg"])
    }

    func testSnapshotListsGalleryState() async {
        let fetcher = GalleryFakeFetcher(root: root, inventory: [photo(2)] + video(1))
        let gallery = InmoGallery(fetcher: fetcher, saver: GalleryFakeSaver(), library: InmoMediaLibrary(directory: root))
        await gallery.saveAll(keys: ["INMOVID_1-900"])
        let rows = gallery.snapshot()["gallery"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["key"] as? String, "INMOIMG_2-100")
        XCTAssertEqual(rows.first?["saved"] as? Bool, false)
        XCTAssertEqual(rows.last?["saved"] as? Bool, true)
        XCTAssertEqual(rows.last?["without_sound"] as? Bool, true)
        XCTAssertEqual(rows.last?["on_glasses"] as? Bool, true)
        XCTAssertEqual(gallery.snapshot()["unsaved"] as? Int, 1)
    }

    // MARK: Render (writes PNGs to RING_SNAPSHOT_DIR or /tmp/ringshots for a look before install)

    func testRenderGalleryCard() async throws {
        let fixtures = ProcessInfo.processInfo.environment["JC_INMO_FIXTURES"] ?? ""
        let library = InmoMediaLibrary(directory: root)
        try FileManager.default.createDirectory(at: library.thumbsDirectory, withIntermediateDirectories: true)
        func thumb(_ key: String, from name: String, kind: InmoGalleryKind, color: UIColor) async throws -> (String, Double?) {
            let file = URL(fileURLWithPath: fixtures).appendingPathComponent(name)
            var made: (jpeg: Data, duration: Double?)?
            if FileManager.default.fileExists(atPath: file.path) { made = try? await InmoMediaThumbnail.make(file, kind: kind) }
            let jpeg = made?.jpeg ?? UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            }.jpegData(compressionQuality: 0.8)!
            try jpeg.write(to: library.thumbsDirectory.appendingPathComponent(key + ".jpg"))
            return (key + ".jpg", made?.duration ?? (kind == .video ? 6.9 : nil))
        }
        let photos: [(Int64, Int)] = [(1790457732024, 1210436), (1790457698483, 1358502), (1790455423193, 1187564),
                                      (1790455394840, 1147657), (1790455390574, 1191965)]
        var inventory = photos.map { InmoMediaItem(name: "INMOIMG_\($0.0).jpg", directory: "D:\\Photos", size: $0.1) }
        inventory += [("mp4", 8418638), ("opus", 15498), ("gcsv", 89838)].map {
            InmoMediaItem(name: "INMOVID_1790457871450.\($0.0)", directory: "D:\\Video", size: $0.1) }
        inventory.append(InmoMediaItem(name: "INMOVID_1790453221036.mp4", directory: "D:\\Video", size: 21061986))
        inventory.append(InmoMediaItem(name: "INMOAUD_1790455500803.opus", directory: "D:\\Audio", size: 62135))
        let saved: [(key: String, name: String, kind: InmoGalleryKind, ms: Int64, silent: Bool, color: UIColor)] = [
            ("INMOIMG_1790455394840-1147657", "INMOIMG_1790455394840.jpg", .photo, 1790455394840, false, .systemTeal),
            ("INMOIMG_1790455390574-1191965", "INMOIMG_1790455390574.jpg", .photo, 1790455390574, false, .systemIndigo),
            ("INMOVID_1790457871450-8418638", "INMOVID_1790457871450.mp4", .video, 1790457871450, false, .systemOrange),
            ("INMOVID_1790453221036-21061986", "INMOVID_1790453221036.mp4", .video, 1790453221036, true, .systemBrown),
            ("INMOIMG_1790400000000-900000", "INMOIMG_1790400000000.jpg", .photo, 1790400000000, false, .systemPink),
        ]
        for entry in saved {
            let (file, duration) = try await thumb(entry.key, from: entry.name, kind: entry.kind, color: entry.color)
            try library.record(InmoGalleryRecord(key: entry.key, kind: entry.kind, capturedAt: Date(timeIntervalSince1970: Double(entry.ms) / 1000),
                                                 parts: [entry.name: 1], savedAt: Date(), withoutSound: entry.silent, duration: duration, thumb: file))
        }
        let gallery = InmoGallery(fetcher: GalleryFakeFetcher(root: root, inventory: inventory), saver: GalleryFakeSaver(), library: library)
        try RenderHarness.write(NavigationStack { ScrollView { InmoMediaView(gallery: gallery).padding(16) } },
                                size: CGSize(width: 402, height: 900), name: "glasses-gallery-card")
        try RenderHarness.write(NavigationStack { InmoGalleryView(gallery: gallery) },
                                size: CGSize(width: 402, height: 900), name: "glasses-gallery-full")
    }

    // MARK: Helpers

    /// A short real H.264 movie, picture only.
    private func makeMovie(seconds: Int) async throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0...(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}

@MainActor
private final class GalleryFakeFetcher: InmoMediaFetching {
    let root: URL
    let inventory: [InmoMediaItem]
    var inventoryChanges: AnyPublisher<[InmoMediaItem], Never> { Empty().eraseToAnyPublisher() }
    var opens = 0, closes = 0, cancels = 0
    var fetched: [String] = []
    var handedOut: [URL] = []
    var failing: Set<String> = []
    private var cancelled = false

    init(root: URL, inventory: [InmoMediaItem]) { self.root = root; self.inventory = inventory }
    func refresh() async throws {}
    func openSession() async throws { opens += 1; cancelled = false }
    func fetch(_ item: InmoMediaItem) async throws -> URL {
        if cancelled { throw CancellationError() }
        fetched.append(item.name)
        if failing.contains(item.name) { throw InmoMediaError(message: "gone") }
        let url = root.appendingPathComponent(UUID().uuidString + "-" + item.name)
        try Data(repeating: 7, count: item.size).write(to: url)
        handedOut.append(url)
        return url
    }
    func closeSession() async { closes += 1 }
    func cancel() { cancels += 1; cancelled = true }
}

@MainActor
private final class GalleryFakeSaver: InmoPhotosSaving {
    var allowed = true
    var fail = false
    var saved: [(name: String, isPhoto: Bool)] = []
    var onSave: (() -> Void)?
    var onAuthorize: (() -> Void)?
    func authorize() async -> Bool { onAuthorize?(); return allowed }
    func save(_ file: URL, name: String, isPhoto: Bool, date: Date) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        if fail { throw InmoMediaError(message: "Photos said no") }
        saved.append((name, isPhoto))
        onSave?()
    }
}

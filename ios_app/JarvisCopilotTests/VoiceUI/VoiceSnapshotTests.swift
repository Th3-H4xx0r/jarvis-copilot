import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Renders the Voice screen into a real `UIWindow` at iPhone 17 Pro Max points and
/// writes a PNG per state, so the port can be compared to the Flutter screen by
/// eye rather than by reading SwiftUI.
///
/// It is NOT a golden-image test — there is no reference to diff against and pixel
/// comparisons in CI rot instantly. What it asserts is that each state actually
/// PAINTS: right size, and enough distinct pixels that a blank screen (a crashed
/// `Canvas`, a view that measured to zero, a black-on-black colour bug) fails.
///
/// Snapshots land in `$VOICE_SNAPSHOT_DIR`, else the scratchpad path below.
@MainActor
final class VoiceSnapshotTests: XCTestCase {

    /// iPhone 17 Pro Max in points.
    private static let size = CGSize(width: 440, height: 956)
    /// The device's own safe area — the window we build has none of its own.
    private static let safeTop: CGFloat = 62
    private static let safeBottom: CGFloat = 34
    /// What `NavShell` reserves on every page for the floating nav pill.
    private static let navReserve: CGFloat = GlassNavBar.reservedHeight

    private static let fallbackDirectory =
        "/private/tmp/claude-501/-Users-pranavkrishna-PranavFiles-coding-projects-JarvisCopilot"
        + "/1e859fd6-70aa-48bf-b84f-8f3c43f1cb44/scratchpad/voice-snapshots"

    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["VOICE_SNAPSHOT_DIR"] ?? Self.fallbackDirectory
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - The four states

    func testRendersEveryVoiceState() throws {
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)

        // Idle — the empty screen: caption, orb, "Idle".
        let idle = mockedStore()
        try snapshot(idle, named: "01-idle")

        // Listening — the user's line has replaced the caption, mic is hot.
        let listening = mockedStore()
        _ = listening.machine.apply(.startRequested)
        _ = listening.machine.apply(.connected)
        listening.userTranscript = "What's the weather like in San Francisco today?"
        listening.amplitude = 0.62
        XCTAssertEqual(listening.state, .listening)
        try snapshot(listening, named: "02-listening")

        // Speaking — a multi-segment reply mid-karaoke.
        let speaking = mockedStore()
        _ = speaking.machine.apply(.startRequested)
        _ = speaking.machine.apply(.connected)
        speaking.userTranscript = "What's the weather like in San Francisco today?"
        _ = speaking.machine.apply(.endOfSpeech)
        speaking.reply.append("Clear skies over the city this afternoon, with the fog "
                            + "holding off until the evening.")
        speaking.reply.append("It should top out around twenty two degrees.")
        _ = speaking.machine.apply(.playbackStarted)
        speaking.reply.clipStarted(tag: 0, durationMs: 4000)
        speaking.reply.clipPosition(tag: 0, positionMs: 1800)
        XCTAssertEqual(speaking.state, .speaking)
        XCTAssertGreaterThan(speaking.spokenWords, 0)
        XCTAssertLessThan(speaking.spokenWords, speaking.reply.totalWords)
        try snapshot(speaking, named: "03-speaking")

        // Error — Flutter shows the failure THROUGH the reply slot, not a banner.
        let failed = mockedStore()
        _ = failed.machine.apply(.failed("Lost the voice connection — tap to try again."))
        failed.error = "Lost the voice connection — tap to try again."
        XCTAssertEqual(failed.state, .error)
        try snapshot(failed, named: "04-error")
    }

    /// The sheet the toolbar chip opens: the model catalogue, the speaking voice
    /// and the turn mode in one place. This is the fix for "it only lets me change
    /// the voice engine, not the model".
    func testRendersTheModelPickerSheet() throws {
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        let store = mockedStore()
        let models = mockedModels()
        let expectation = expectation(description: "catalogue")
        Task { await models.load(); expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(models.catalog?.models.count, 3)

        let image = render(VoiceModelPickerSheet(store: store, models: models))
        try write(image, named: "05-model-picker")
        assertPainted(image, name: "05-model-picker")
    }

    // MARK: - Snapshotting

    private func snapshot(_ store: VoiceStore, named name: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        // The shell inserts the nav-bar reserve on every page; a snapshot without
        // it would put the mic button where the pill will be.
        let page = VoicePage(store: store, models: mockedModels())
            .environment(AppRouter())
            .safeAreaInset(edge: .bottom, spacing: 0) { navBarStandIn }
        let image = render(page)
        try write(image, named: name)
        assertPainted(image, name: name, file: file, line: line)
    }

    /// A stand-in for the shell's floating nav pill, drawn INSIDE the 74 pt the
    /// shell reserves. Without it a snapshot can't show whether the mic button
    /// actually clears the bar — which is the bug that started this pass.
    private var navBarStandIn: some View {
        let shape = RoundedRectangle(cornerRadius: JcTheme.pillRadius, style: .continuous)
        return shape.fill(Color(jcHex: 0x0E0E18))
            .overlay(shape.strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .frame(height: GlassNavBar.barHeight)
            .padding(.horizontal, 16)
            .padding(.bottom, GlassNavBar.bottomClearance)
            .frame(height: Self.navReserve)
    }

    private func render(_ view: some View) -> UIImage {
        let host = UIHostingController(rootView:
            view.preferredColorScheme(.dark)
                .background(JcTheme.bg))
        host.view.frame = CGRect(origin: .zero, size: Self.size)
        host.view.backgroundColor = UIColor(JcTheme.bg)

        // A real, on-screen window on the host app's own scene. Detached windows
        // never reach the render server (so `drawHierarchy` captures nothing) AND
        // SwiftUI declines to install a `UINavigationBar` in them, which silently
        // drops the whole toolbar — the model chip included.
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        // Only fake the device's safe area when the window didn't inherit one
        // (an unattached window has none, and the layout would then be wrong).
        if window.safeAreaInsets.top < 1 {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: Self.safeTop, left: 0,
                                                         bottom: Self.safeBottom, right: 0)
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Let SwiftUI commit its first frame — the orb's `Canvas` and the
        // navigation bar are both produced asynchronously.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let renderer = UIGraphicsImageRenderer(size: Self.size)
        let image = renderer.image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private func write(_ image: UIImage, named name: String) throws {
        let url = outputDirectory.appendingPathComponent("\(name).png")
        let data = try XCTUnwrap(image.pngData(), "no PNG for \(name)")
        try data.write(to: url)
    }

    /// A screen that renders as one flat colour is a failure, however green the
    /// layout assertions are.
    private func assertPainted(_ image: UIImage, name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.size.width, Self.size.width, accuracy: 0.5, name,
                       file: file, line: line)
        XCTAssertEqual(image.size.height, Self.size.height, accuracy: 0.5, name,
                       file: file, line: line)
        XCTAssertGreaterThan(distinctColours(in: image), 24,
                             "\(name) rendered nearly blank", file: file, line: line)
    }

    /// Count colour buckets across a coarse grid — cheap, and enough to tell a
    /// painted screen from an empty one.
    private func distinctColours(in image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = 44, height = 96
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = UInt32(pixels[i] >> 3), g = UInt32(pixels[i + 1] >> 3), b = UInt32(pixels[i + 2] >> 3)
            buckets.insert(r << 10 | g << 5 | b)
        }
        return buckets.count
    }

    // MARK: - Fixtures

    /// A store with every platform boundary mocked and no launch latch, so
    /// building the page can't start a turn or touch the mic.
    private func mockedStore() -> VoiceStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/engines", json: ["engines": [], "active": ""])
        transport.route("/api/devices", json: [])
        return VoiceStore(api: api,
                          input: MockAudioInput(),
                          output: MockAudioOutput(),
                          recognizer: MockSpeechRecognizing(),
                          synthesizer: MockVoiceSynthesizing(),
                          audioSession: MockAudioSessionControlling(),
                          connector: MockVoiceSocketConnector(),
                          clock: TestVoiceClock(),
                          keyValueStore: MemoryKeyValueStore(),
                          launch: nil,
                          local: nil)
    }

    private func mockedModels() -> VoiceModelStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/models", json: [
            "default_model": "anthropic/claude-haiku-4.5",
            "active_provider": "anthropic",
            "groups": [
                ["provider": "Anthropic", "provider_id": "anthropic", "models": [
                    ["id": "anthropic/claude-opus-4.7", "label": "Claude Opus 4.7"],
                    ["id": "anthropic/claude-haiku-4.5", "label": "Claude Haiku 4.5"],
                ]],
                ["provider": "OpenAI", "provider_id": "openai", "models": [
                    ["id": "openai/gpt-5.2", "label": "GPT-5.2"],
                ]],
            ],
        ])
        return VoiceModelStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()))
    }
}

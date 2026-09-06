import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Renders the Devices tab to PNGs so the design can actually be looked at.
///
/// The assertions stay structural (the tree laid out, the bitmap has pixels and
/// isn't one flat colour) so the class is safe in a headless CI run; the files it
/// drops in `devicesSnapshotDirectory` are the point of it during design work.
@MainActor
final class DevicesSnapshotTests: XCTestCase {

    /// iPhone 17 Pro Max-ish logical size — the widest layout the page has to
    /// hold, where loose spacing shows up first.
    private static let canvas = CGSize(width: 440, height: 956)

    /// Where the PNGs land. Absolute, because the simulator's own tmp is thrown
    /// away with the test run.
    private static let outputDirectory = URL(fileURLWithPath:
        "/private/tmp/claude-501/-Users-pranavkrishna-PranavFiles-coding-projects-JarvisCopilot"
        + "/1e859fd6-70aa-48bf-b84f-8f3c43f1cb44/scratchpad/devices-snapshots")

    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: Harness

    /// Mount `view` the way the shell does — dark, on the app background, with the
    /// floating nav bar's 74pt bottom inset reserved — render it, and write the
    /// PNG.
    @discardableResult
    private func snapshot(_ view: some View,
                          named name: String,
                          file: StaticString = #filePath,
                          line: UInt = #line) -> UIImage? {
        // No explicit frame here: the hosting controller's view is already the
        // canvas, and a fixed-size frame inside it centres and overflows once the
        // safe-area insets shrink the space it is offered.
        let root = ZStack {
            JcTheme.bg.ignoresSafeArea()
            view
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The shell reserves this on every page; reproducing it here keeps the
        // snapshot honest about how much room the content really has.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 74) }
        .preferredColorScheme(.dark)

        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
        controller.view.frame = CGRect(origin: .zero, size: Self.canvas)
        controller.view.backgroundColor = .black

        // The window MUST belong to the test host's scene. An unattached
        // `UIWindow` never reaches the render server, and `drawHierarchy` then
        // hands back a blank bitmap however correct the layout is.
        let window = Self.sceneWindow(size: Self.canvas)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows.append(window)

        // The real device's own safe area, so content sits where it will on a
        // phone rather than against the top edge.
        let have = window.safeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(
            top: max(0, 62 - have.top), left: 0,
            bottom: max(0, 34 - have.bottom), right: 0)

        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // SwiftUI commits its first real display pass on the next runloop turn;
        // without this the bitmap can come back as bare background.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.setNeedsLayout()
        window.layoutIfNeeded()

        XCTAssertEqual(controller.view.bounds.size, Self.canvas,
                       "hosted view lost its frame", file: file, line: line)

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        guard let data = image.pngData(), !data.isEmpty else {
            XCTFail("could not encode \(name)", file: file, line: line)
            return nil
        }
        XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
        XCTAssertTrue(Self.hasContrast(image),
                      "\(name) rendered as one flat colour", file: file, line: line)

        do {
            try FileManager.default.createDirectory(at: Self.outputDirectory,
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        } catch {
            // A sandbox that won't let the test write is not a UI failure; the
            // render above is still the assertion that matters.
            print("devices snapshot \(name) not written: \(error)")
        }
        return image
    }

    /// A window on the test host's foreground scene, which is what makes the
    /// render server composite it.
    private static func sceneWindow(size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    /// True when the bitmap holds more than one colour — proof something drew,
    /// as opposed to a window that never rendered its tree.
    private static func hasContrast(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = Array(pixels[0..<3])
        for index in stride(from: 0, to: pixels.count, by: 4 * 97) {
            if abs(Int(pixels[index]) - Int(first[0])) > 6
                || abs(Int(pixels[index + 1]) - Int(first[1])) > 6
                || abs(Int(pixels[index + 2]) - Int(first[2])) > 6 {
                return true
            }
        }
        return false
    }

    // MARK: Snapshots

    /// The tab as the user meets it: segmented control, server summary, three
    /// paired devices with their skills collapsed, one primary action.
    func testServerTabSnapshot() async {
        let store = await DevicesFixtures.loadedStore()
        XCTAssertEqual(store.devices.count, 3)
        XCTAssertNil(store.errorMessage)
        snapshot(DevicesPage(store: store, section: .server), named: "01-server")
    }

    /// The disclosure open: thirty-two granted skills as a plain grouped list with
    /// human names, which is the state the old chip wall was permanently in.
    func testExpandedSkillsSnapshot() async {
        let store = await DevicesFixtures.loadedStore()
        let phone = store.devices[0]
        let skills = store.grantedSkills(for: phone)
        XCTAssertEqual(skills.count, DevicesFixtures.phoneSkillNames.count)

        snapshot(
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DevicesHealthStrip(health: store.health, wiki: store.wiki)
                    DeviceServerCard(device: phone, skills: skills,
                                     isThisDevice: true, expanded: true,
                                     onLogout: {}, onRevoke: {})
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(AuroraBackdrop().ignoresSafeArea()),
            named: "02-skills-expanded")
    }

    /// Nothing paired yet.
    func testEmptySnapshot() async {
        let store = await DevicesFixtures.emptyStore()
        XCTAssertTrue(store.isEmpty)
        snapshot(DevicesPage(store: store, section: .server), named: "03-empty")
    }

    /// The list endpoint refusing us — the full-screen error branch with its retry.
    func testErrorSnapshot() async {
        let store = await DevicesFixtures.failedStore()
        XCTAssertEqual(store.errorMessage, "Not paired with this server")
        XCTAssertTrue(store.devices.isEmpty)
        snapshot(DevicesPage(store: store, section: .server), named: "04-error")
    }

    /// A refresh that failed over rows that are still good: the banner, not the
    /// error screen.
    func testStaleBannerSnapshot() async {
        let store = await DevicesFixtures.loadedStore()
        snapshot(DevicesServerSection(store: store)
            .loadErrorBanner("Couldn't reach the server — showing the last known devices.",
                             hasContent: true)
            .background(AuroraBackdrop().ignoresSafeArea()),
                 named: "05-stale-banner")
    }
}

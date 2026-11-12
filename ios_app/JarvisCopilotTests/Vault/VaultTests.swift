import SwiftUI
import XCTest
@testable import JarvisCopilot

final class VaultModelTests: XCTestCase {
    func testLinkItemParsesPreviewAndGetsTheWideCard() throws {
        let item = try XCTUnwrap(VaultItem(json: [
            "id": "a1", "parent_id": "root", "kind": "link", "title": "Bullet trains", "created": 1_762_900_000,
            "updated": 1_762_900_000, "size": 0, "has_thumb": true, "thumb_w": 640, "thumb_h": 360,
            "duration_s": 872, "link": ["url": "https://youtu.be/x", "site_name": "YouTube", "domain": "youtube.com",
                                        "kind": "video", "author": "Rail Explained", "has_favicon": true],
        ]))
        XCTAssertTrue(item.isWide)
        XCTAssertEqual(item.metaLine, "YouTube · Rail Explained")
        XCTAssertEqual(VaultFormat.duration(item.duration), "14:32")
        XCTAssertEqual(try XCTUnwrap(item.thumbAspect), 640.0 / 360.0, accuracy: 0.001)
    }

    func testUnknownKindIsDropped() {
        XCTAssertNil(VaultItem(json: ["id": "x", "kind": "spaceship"]))
    }

    func testArticleLinkIsNotWideAndTitleFallsBackToDomain() throws {
        let item = try XCTUnwrap(VaultItem(json: ["id": "b", "kind": "link",
                                                  "link": ["url": "https://example.com/post", "kind": "article"]]))
        XCTAssertFalse(item.isWide)
        XCTAssertEqual(item.displayTitle, "example.com")
    }

    func testDurationFormatsHoursAndRejectsJunk() {
        XCTAssertEqual(VaultFormat.duration(3725), "1:02:05")
        XCTAssertNil(VaultFormat.duration(nil))
        XCTAssertNil(VaultFormat.duration(.nan))
        XCTAssertNil(VaultFormat.duration(0))
    }

    func testEveryJarvisVaultCommandHasAnAppTitle() {
        for command in ["search", "list", "read", "save", "move", "delete"] {
            XCTAssertNotNil(VaultApprovalDomain.titles[command], command)
        }
    }
}

/// Renders the vault's pieces to /tmp/ringshots for a look before they reach the phone.
@MainActor
final class VaultRenderTests: XCTestCase {
    private func item(_ o: [String: Any]) -> VaultItem { VaultItem(json: o)! }

    private var sample: [VaultItem] {
        [
            item(["id": "1", "kind": "link", "title": "How Japan's bullet trains run on time, every time",
                  "duration_s": 872, "link": ["url": "https://youtu.be/x", "site_name": "YouTube", "kind": "video",
                                              "author": "Rail Explained"]]),
            item(["id": "2", "kind": "note", "title": "Wi-Fi + door codes",
                  "snippet": "Garage keypad: change monthly\nStorage unit #214", "updated": Date().timeIntervalSince1970]),
            item(["id": "3", "kind": "pdf", "title": "Lease agreement", "pages": 14, "size": 1_200_000]),
            item(["id": "4", "kind": "file", "title": "backup-codes", "filename": "backup-codes.txt", "size": 2048]),
            item(["id": "5", "kind": "video", "title": "Apartment walkthrough", "duration_s": 48, "size": 84_000_000]),
        ]
    }

    func testRenderVaultGridAndList() throws {
        let session = VaultSession()
        let sample = self.sample
        let folders = [VaultFolder(id: "f1", parentID: "root", name: "Taxes", count: 8),
                       VaultFolder(id: "f2", parentID: "root", name: "Watch later", count: 15)]
        let page = ScrollView {
            JcPageColumn {
                JcSectionLabel("Folders", first: true)
                HStack(spacing: 10) { ForEach(folders) { VaultFolderTile(folder: $0) } }
                JcSectionLabel("Items")
                VStack(spacing: 10) {
                    VaultGridCard(item: sample[0], session: session)
                    HStack(alignment: .top, spacing: 10) {
                        VaultGridCard(item: sample[1], session: session)
                        VaultGridCard(item: sample[2], session: session, selecting: true, selected: true)
                    }
                }
                JcSectionLabel("List")
                JcCard(padding: 0) {
                    ForEach(Array(sample.enumerated()), id: \.element.id) { i, it in
                        VaultListRow(item: it, session: session, last: i == sample.count - 1)
                    }
                }
            }
        }
        try RenderHarness.write(page, size: CGSize(width: 393, height: 1500), name: "vault-folder", settle: 1)
    }

    func testRenderLockAndPasscode() throws {
        try RenderHarness.write(VaultLockView(session: VaultSession()), size: CGSize(width: 393, height: 852),
                                name: "vault-lock", settle: 1.5)
    }
}

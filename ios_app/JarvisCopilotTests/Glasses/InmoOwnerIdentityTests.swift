import XCTest
import Security
@testable import JarvisCopilot

final class InmoOwnerIdentityTests: XCTestCase {
    private var service: String!
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service!, kSecAttrAccount as String: "owner"]
    }
    override func setUp() { super.setUp(); service = "Jarvis.InmoGO3.Tests.\(UUID().uuidString)" }
    override func tearDown() { SecItemDelete(query as CFDictionary); super.tearDown() }

    private func item() throws -> [String: Any] {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(request as CFDictionary, &result), errSecSuccess)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testLegacyOwnerMigratesInPlaceWithoutChangingIdentity() throws {
        let identity = Data([0x31, 0x42, 0x53])
        var legacy = query
        legacy[kSecValueData as String] = identity
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        let creationDate = try item()[kSecAttrCreationDate as String] as? Date

        XCTAssertEqual(InmoOwnerIdentityStore(service: service).read(), identity)

        let migrated = try item()
        XCTAssertEqual(migrated[kSecValueData as String] as? Data, identity)
        XCTAssertEqual(migrated[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(migrated[kSecAttrCreationDate as String] as? Date, creationDate)
    }

    func testSaveCreatesAndUpdatesBackgroundAccessibleOwner() throws {
        let store = InmoOwnerIdentityStore(service: service)
        try store.save(Data([0x11]))
        try store.save(Data([0x22, 0x33]))
        XCTAssertEqual(store.read(), Data([0x22, 0x33]))
        XCTAssertEqual(try item()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testInvalidReplacementPreservesSavedOwner() throws {
        let store = InmoOwnerIdentityStore(service: service)
        try store.save(Data([0x44]))
        XCTAssertThrowsError(try store.save(Data()))
        XCTAssertThrowsError(try store.save(Data(repeating: 0, count: 1025)))
        XCTAssertEqual(store.read(), Data([0x44]))
    }

    func testReadOfMissingOwnerDoesNotCreateIdentity() {
        XCTAssertNil(InmoOwnerIdentityStore(service: service).read())
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
    }
}

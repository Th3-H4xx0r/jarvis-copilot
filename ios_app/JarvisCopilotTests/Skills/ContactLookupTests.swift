import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/skills/contact_lookup_test.dart`.
final class ContactLookupTests: XCTestCase {
    private func c(_ name: String, _ phones: [String]) -> ContactRecord {
        ContactRecord(name: name, phones: phones)
    }

    // MARK: cleanNumber

    func testCleanNumberKeepsSingleLeadingPlusAndDigitsOnly() {
        XCTAssertEqual(ContactLookup.cleanNumber("+1 (510) 378-0762"), "+15103780762")
        XCTAssertEqual(ContactLookup.cleanNumber("510-378-0762"), "5103780762")
    }

    func testCleanNumberReturnsNonNumericTextTrimmed() {
        XCTAssertEqual(ContactLookup.cleanNumber("  hi "), "hi")
    }

    // MARK: bestContactNumber

    private var contacts: [ContactRecord] {
        [
            c("Chahel Singh", ["+1 510-378-0762"]),
            c("Chad", ["+1 415 000 1111"]),
            c("Mom", ["(212) 555-0100"]),
            c("No Number", []),
        ]
    }

    func testExactNameBeatsPrefixAndContains() {
        XCTAssertEqual(
            ContactLookup.bestContactNumber([c("Chahel", ["111"]), c("Chahel Singh", ["222"])],
                                            query: "Chahel"),
            "111")
    }

    func testPrefixMatchWhenNoExact() {
        XCTAssertEqual(ContactLookup.bestContactNumber(contacts, query: "chahel"), "+15103780762")
    }

    func testCaseInsensitiveContainsMatch() {
        XCTAssertEqual(ContactLookup.bestContactNumber(contacts, query: "mom"), "2125550100")
    }

    func testSkipsContactsWithNoPhone() {
        XCTAssertNil(ContactLookup.bestContactNumber(contacts, query: "no number"))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(ContactLookup.bestContactNumber(contacts, query: "zzz"))
        XCTAssertNil(ContactLookup.bestContactNumber(contacts, query: ""))
    }

    // MARK: resolveRecipient (phone-like input never hits the contact store)

    func testResolveRecipientCleansAPhoneLikeValueWithoutLookup() async {
        let store = MockContactsStore(granted: false, contacts: [])
        let resolved = await ContactLookup.resolveRecipient("+1 (510) 378-0762", store: store)
        XCTAssertEqual(resolved, "+15103780762")
        XCTAssertEqual(store.accessRequests, 0)
    }

    func testResolveRecipientFallsBackToRawTextWhenPermissionDenied() async {
        let store = MockContactsStore(granted: false, contacts: [c("Chahel Singh", ["+15103780762"])])
        let resolved = await ContactLookup.resolveRecipient("Chahel", store: store)
        XCTAssertEqual(resolved, "Chahel")
    }

    func testResolveRecipientLooksUpAName() async {
        let store = MockContactsStore(granted: true, contacts: [c("Chahel Singh", ["+1 510-378-0762"])])
        let resolved = await ContactLookup.resolveRecipient("chahel", store: store)
        XCTAssertEqual(resolved, "+15103780762")
    }

    func testResolveRecipientKeepsRawTextOnNoMatch() async {
        let store = MockContactsStore(granted: true, contacts: [c("Mom", ["1"])])
        let resolved = await ContactLookup.resolveRecipient("Zebedee", store: store)
        XCTAssertEqual(resolved, "Zebedee")
    }
}

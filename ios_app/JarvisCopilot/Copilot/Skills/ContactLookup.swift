import Foundation

/// One device contact, flattened to the fields the skills actually send back.
struct ContactRecord: Equatable, Sendable {
    let name: String
    let phones: [String]
    let emails: [String]

    init(name: String, phones: [String], emails: [String] = []) {
        self.name = name
        self.phones = phones
        self.emails = emails
    }
}

/// Read-only contacts boundary (`CNContactStore` in production, a mock in tests).
protocol ContactsStore: Sendable {
    /// Prompts on first call; false when the user has denied access, throws
    /// when the request itself failed (so a skill can say which it was).
    func requestAccess() async throws -> Bool
    func contacts() async throws -> [ContactRecord]
}

/// Resolve a send-message recipient to a concrete handle the iOS Shortcuts
/// "Send Message" action can use. Send Message fails with "couldn't convert from
/// Text to Contact, Phone Number, or Email Address" when handed loose name text
/// it can't match — so we look the name up in the device contacts FIRST and pass
/// a bare phone number (which never needs conversion). Mirrors what Siri does
/// behind the scenes.
///
/// Port of `mobile_client/lib/skills/contact_lookup.dart`.
enum ContactLookup {
    private static let phoneLike = Rx(#"^[+()\-.\s\d]{4,}$"#)

    /// Strip a phone number to a dialable form: digits, keeping a single
    /// leading `+`.
    static func cleanNumber(_ raw: String) -> String {
        let plus = raw.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }).first == "+"
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        if digits.isEmpty { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return plus ? "+\(digits)" : String(digits)
    }

    /// Pure recipient matcher — kept free of platform code so it can be unit
    /// tested. Ranking: exact display-name match > name starts-with query >
    /// name contains query. Contacts with no phone are skipped. Returns the
    /// chosen number cleaned, or nil when nothing matches.
    static func bestContactNumber(_ contacts: [ContactRecord], query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return nil }
        var exact: ContactRecord?
        var prefix: ContactRecord?
        var sub: ContactRecord?
        for c in contacts {
            if c.phones.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            let n = c.name.lowercased()
            if n == q {
                if exact == nil { exact = c }
            } else if n.hasPrefix(q) {
                if prefix == nil { prefix = c }
            } else if n.contains(q) {
                if sub == nil { sub = c }
            }
        }
        guard let pick = exact ?? prefix ?? sub else { return nil }
        for p in pick.phones where !p.trimmingCharacters(in: .whitespaces).isEmpty {
            return cleanNumber(p)
        }
        return nil
    }

    /// Look up `to` in the device contacts and return a dialable handle. A value
    /// that already looks like a phone number is cleaned and returned as-is (no
    /// lookup). On no permission / no match / any error, the original text is
    /// returned so the Shortcut can still try (best-effort).
    static func resolveRecipient(_ to: String, store: any ContactsStore) async -> String {
        let raw = to.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return raw }
        if phoneLike.hasMatch(raw) { return cleanNumber(raw) }
        do {
            guard try await store.requestAccess() else { return raw }
            return bestContactNumber(try await store.contacts(), query: raw) ?? raw
        } catch {
            // Best-effort by design: the composer can still try the raw name.
            JcLog.dropped(JcLog.skills, "contact lookup", error)
            return raw
        }
    }
}

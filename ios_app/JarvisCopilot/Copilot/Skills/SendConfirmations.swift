import Contacts
import Foundation
import SwiftUI
import UIKit

/// Who a number or address belongs to, for the call/text card: the full name and photo from the
/// phone's own Contacts. Never asks for access — the card is shown from the background too.
struct ContactCardInfo: Equatable, Sendable {
    let name: String
    let photo: Data?
}

protocol ContactCardLooking: Sendable {
    func lookup(_ handle: String) async -> ContactCardInfo?
}

final class DefaultContactCardLookup: ContactCardLooking {
    func lookup(_ handle: String) async -> ContactCardInfo? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var allowed = status == .authorized
        if #available(iOS 18.0, *), status == .limited { allowed = true }
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowed, !trimmed.isEmpty, !trimmed.contains(":") else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        // A name ("Mom") as the Mac's Messages takes it, else a number or an address.
        let predicate = trimmed.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: trimmed)
            : trimmed.filter(\.isNumber).count < 3
                ? CNContact.predicateForContacts(matchingName: trimmed)
                : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: trimmed))
        guard let contact = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys).first,
              let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty
        else { return nil }
        return ContactCardInfo(name: name, photo: contact.thumbnailImageData)
    }
}

/// The call/text card (Pranav, 2026-10-18): before Jarvis calls or sends anything to someone on a
/// voice turn it asks, and the server puts this card up on the iPhone the turn came from — the
/// person's photo and full name, the message, Send (Call) and ✕ — on the car's screen in CarPlay
/// and over the app when it's open. Send is his "Yes." and ✕ his "No.", said into the conversation
/// (the server reads them like spoken answers, agent/send_confirm.py); the server closes the card
/// once he has answered. It goes by itself when its two minutes are up.
@MainActor
final class SendConfirmations: ObservableObject {
    static let shared = SendConfirmations(contacts: DefaultContactCardLookup(), voice: .shared)
    static let skillName = "confirm_card"

    struct Item: Equatable {
        enum Kind: String { case call, text, email, message }
        let kind: Kind
        let to: String
        let text: String
        let subject: String
        let via: String
    }

    struct Card: Equatable {
        let id: String
        let items: [Item]
        let deadline: Date
        var name: String?
        var photo: Data?

        var first: Item { items[0] }
        var title: String { name ?? first.to }
        var actionTitle: String { first.kind == .call ? "Call" : "Send" }
        var actionSymbol: String {
            switch first.kind {
            case .call: return "phone.fill"
            case .email: return "envelope.fill"
            case .text, .message: return "paperplane.fill"
            }
        }
        /// "Text · +1 209…", "Email · shabd@…", "+1 more" when one answer covers several.
        var subtitle: String {
            let what: String
            switch first.kind {
            case .call: what = first.via == "FaceTime" ? "FaceTime" : "Call"
            case .text: what = "Text"
            case .email: what = "Email"
            case .message: what = first.via.isEmpty ? "Message" : first.via.capitalized
            }
            let more = items.count > 1 ? " · +\(items.count - 1) more" : ""
            return "\(what) · \(first.to)\(more)"
        }
        /// What he's sending, as he'd read it: the subject over the body for an email.
        var message: String {
            [first.subject, first.text].filter { !$0.isEmpty }.joined(separator: "\n")
        }

        static func initials(of name: String) -> String {
            String(name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }).uppercased()
        }
    }

    enum Outcome: String { case sent, failed, cancelled }

    @Published private(set) var card: Card?
    /// How it went, shown on the card for a moment before it goes.
    @Published private(set) var outcome: Outcome?
    /// A button was tapped and its answer is on its way.
    @Published private(set) var answering = false

    /// His answer, into the conversation; false when it couldn't go out. Set from `voice`
    /// (tests replace it).
    var answer: (Bool) async -> Bool = { _ in false }
    var outcomeHold: Duration = .seconds(1.6)
    /// A tap whose answer never got an outcome (the session dropped it) frees the buttons.
    var answerTimeout: Duration = .seconds(20)
    private var answerWatch: Task<Void, Never>?

    private let contacts: ContactCardLooking
    private var expiry: Task<Void, Never>?
    private var hold: Task<Void, Never>?
    private var window: UIWindow?
    private var active = UIApplication.shared.applicationState == .active
    private var observers: [NSObjectProtocol] = []

    init(contacts: ContactCardLooking, voice: VoiceStore?) {
        self.contacts = contacts
        if let voice {
            answer = { yes in await voice.submitTyped(yes ? "Yes." : "No.") }
            voice.awaitingAnswer = { [weak self] in self?.card != nil && self?.outcome == nil }
            watchTheApp()
        }
    }

    // MARK: The skill

    static func skill() -> AnySkill {
        AnySkill(
            name: skillName,
            description: "Show or close the call/text confirmation card, or name a contact for one. Server use only.",
            inputSchema: SkillSchema.object([
                "action": SkillSchema.string("show | close | lookup"),
                "id": SkillSchema.string(),
                "to": SkillSchema.string("lookup: a number, address or name"),
            ], required: ["action", "id"])
        ) { args in
            await SendConfirmations.shared.handle(args)
        }
    }

    func handle(_ args: [String: Any]) async -> [String: Any] {
        let id = SkillArgs.string(args, "id")
        switch SkillArgs.string(args, "action") {
        case "close":
            close(id: id, outcome: Outcome(rawValue: SkillArgs.string(args, "outcome")) ?? .cancelled)
            return ["closed": true]
        case "show":
            let items = (args["items"] as? [[String: Any]] ?? []).compactMap(Self.item)
            guard !id.isEmpty, !items.isEmpty else { return ["error": "a card needs an id and items"] }
            let seconds = (args["expires_in"] as? Double) ?? (args["expires_in"] as? Int).map(Double.init) ?? 120
            await show(Card(id: id, items: items, deadline: Date().addingTimeInterval(max(0, seconds))))
            return ["shown": true]
        case "lookup":
            // A chat's card (web, Mac, this app's chat) shows the person as this phone knows them.
            guard let info = await contacts.lookup(SkillArgs.string(args, "to")) else { return ["found": false] }
            return ["name": info.name, "photo": Self.cardPhoto(info.photo)?.base64EncodedString() ?? ""]
        default:
            return ["error": "action must be show, close or lookup"]
        }
    }

    /// A contact's photo small enough to ride in a chat event: a 120 px JPEG.
    static func cardPhoto(_ data: Data?) -> Data? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 120
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8)
    }

    private static func item(_ raw: [String: Any]) -> Item? {
        guard let kind = Item.Kind(rawValue: SkillArgs.string(raw, "kind")) else { return nil }
        return Item(kind: kind, to: SkillArgs.string(raw, "to"), text: SkillArgs.string(raw, "text"),
                    subject: SkillArgs.string(raw, "subject"), via: SkillArgs.string(raw, "via"))
    }

    // MARK: Showing, answering, closing

    private func show(_ new: Card) async {
        var new = new
        if let found = await contacts.lookup(new.first.to) {
            new.name = found.name
            new.photo = found.photo
        }
        hold?.cancel()
        outcome = nil
        answering = false
        card = new
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.01, new.deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.card?.id == new.id else { return }
            self.takeDown()
        }
        updateWindow()
    }

    /// Send (yes) or ✕ (no): his answer, once, into the conversation.
    func tap(yes: Bool) async {
        guard let card, outcome == nil, !answering else { return }
        answering = true
        guard await answer(yes) else {
            answering = false
            return
        }
        answerWatch?.cancel()
        let wait = answerTimeout
        answerWatch = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.card?.id == card.id, self.outcome == nil else { return }
            self.answering = false
        }
    }

    private func close(id: String, outcome: Outcome) {
        guard let card, card.id == id else { return }
        expiry?.cancel()
        guard outcome != .cancelled else { return takeDown() }
        self.outcome = outcome
        hold?.cancel()
        let pause = outcomeHold
        hold = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, self.card?.id == card.id else { return }
            self.takeDown()
        }
    }

    private func takeDown() {
        card = nil
        outcome = nil
        answering = false
        updateWindow()
    }

    // MARK: Over the app

    private func watchTheApp() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = true; self?.updateWindow() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = false; self?.updateWindow() }
            },
        ]
    }

    private func updateWindow() {
        guard !observers.isEmpty else { return }   // only the app's own card has a window
        if active, card != nil { showWindow() } else { hideWindow() }
    }

    private func showWindow() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: SendConfirmCard(center: self))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        made.backgroundColor = .clear
        made.rootViewController = host
        made.isHidden = false
        window = made
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    private func hideWindow() {
        window?.isHidden = true
        window = nil
    }
}

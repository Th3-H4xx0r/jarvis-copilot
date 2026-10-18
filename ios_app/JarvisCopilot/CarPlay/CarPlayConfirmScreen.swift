import CarPlay
import Combine
import UIKit

/// What the car's call/text screen says, from the card alone (tested without CarPlay).
struct CarPlayConfirmText: Equatable {
    struct Button: Equatable {
        let title: String
        let symbol: String
        let yes: Bool
    }

    let title: String
    let subtitle: String
    let rows: [String]
    let buttons: [Button]
    let enabled: Bool

    static func make(_ card: SendConfirmations.Card, outcome: SendConfirmations.Outcome?, answering: Bool) -> Self {
        let rows = card.message.isEmpty ? [card.first.to] : [card.message]
        if let outcome {
            let said = outcome == .sent ? (card.first.kind == .call ? "Calling…" : "Sent") : "Didn't go through"
            return Self(title: card.title, subtitle: said, rows: rows, buttons: [], enabled: false)
        }
        return Self(title: card.title, subtitle: card.subtitle, rows: rows,
                    buttons: [Button(title: card.actionTitle, symbol: card.actionSymbol, yes: true),
                              Button(title: "Cancel", symbol: "xmark", yes: false)],
                    enabled: !answering)
    }
}

/// The call/text card on the car's screen (`SendConfirmations`): a screen pushed over the Voice tab
/// whose header is the card — the person's photo, full name, what Jarvis would do — with Send (Call)
/// and ✕ as its buttons, and the message under it. It sits above the voice card, which keeps
/// listening for his spoken yes or no; the screen goes when the server closes the card.
@available(iOS 26.4, *)
@MainActor
final class CarPlayConfirmScreen {
    private let ui: CPInterfaceController
    private var template: CPListTemplate?
    private var shownID: String?
    /// The card he backed out of: not pushed again (the question still stands by voice).
    private var dismissedID: String?
    private var cancellable: AnyCancellable?
    /// Puts the Voice tab in front, at its root, before the screen is pushed over it.
    var bringVoiceTabForward: () -> Void = {}

    init(ui: CPInterfaceController) {
        self.ui = ui
    }

    func attach(_ center: SendConfirmations = .shared) {
        // @Published sends the new values before the store changes: render from them.
        cancellable = center.$card.combineLatest(center.$outcome, center.$answering)
            .sink { [weak self] card, outcome, answering in
                Task { @MainActor in self?.render(card, outcome: outcome, answering: answering, center: center) }
            }
    }

    func detach() {
        cancellable = nil
        template = nil
        shownID = nil
    }

    func owns(_ aTemplate: CPTemplate) -> Bool { aTemplate === template }

    /// Back on the car (or the system) took the screen.
    func templateGone() {
        dismissedID = shownID
        template = nil
        shownID = nil
    }

    private func render(_ card: SendConfirmations.Card?, outcome: SendConfirmations.Outcome?,
                        answering: Bool, center: SendConfirmations) {
        guard let card, card.id != dismissedID else {
            if let template {
                self.template = nil
                shownID = nil
                if ui.topTemplate === template { ui.popTemplate(animated: true, completion: nil) }
            }
            return
        }
        let text = CarPlayConfirmText.make(card, outcome: outcome, answering: answering)
        let buttons = text.buttons.map { spec -> CPButton in
            let button = CPButton(image: Self.symbol(spec.symbol)) { _ in
                Task { await center.tap(yes: spec.yes) }
            }
            button.title = spec.title
            button.isEnabled = text.enabled
            return button
        }
        let header = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: Self.avatar(card)),
                                                 title: text.title, subtitle: text.subtitle, actionButtons: buttons)
        let sections = [CPListSection(items: text.rows.map { CPListItem(text: $0, detailText: nil) })]
        if let template, shownID == card.id {
            template.listHeader = header
            template.updateSections(sections)
            return
        }
        if let template, ui.topTemplate === template { ui.popTemplate(animated: false, completion: nil) }
        let made = CPListTemplate(title: card.actionTitle, sections: sections)
        made.listHeader = header
        template = made
        shownID = card.id
        bringVoiceTabForward()
        ui.pushTemplate(made, animated: true) { ok, error in
            cpDiag("confirm screen pushed=\(ok) \(error?.localizedDescription ?? "")")
        }
    }

    // MARK: Pictures

    private static func symbol(_ name: String) -> UIImage {
        let side = min(CPListTemplateDetailsHeader.maximumActionButtonSize.height, 44)
        let config = UIImage.SymbolConfiguration(pointSize: max(16, side * 0.5), weight: .semibold)
        return UIImage(systemName: name, withConfiguration: config) ?? UIImage()
    }

    /// The person's Contacts photo in a circle, else their initials (or a person glyph) on the accent.
    static func avatar(_ card: SendConfirmations.Card, side: CGFloat = 120) -> UIImage {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            if let data = card.photo, let photo = UIImage(data: data) {
                let scale = max(side / photo.size.width, side / photo.size.height)
                let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
                return
            }
            UIColor(JcTheme.accent).withAlphaComponent(0.3).setFill()
            UIRectFill(rect)
            let initials = SendConfirmations.Card.initials(of: card.name ?? "")
            if initials.isEmpty {
                let glyph = UIImage(systemName: "person.fill", withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: side * 0.42, weight: .medium))?
                    .withTintColor(UIColor(JcTheme.accent), renderingMode: .alwaysOriginal)
                if let glyph {
                    glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
                }
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: side * 0.38, weight: .semibold),
                    .foregroundColor: UIColor(JcTheme.accent),
                ]
                let text = initials as NSString
                let measured = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2), withAttributes: attrs)
            }
        }
    }
}

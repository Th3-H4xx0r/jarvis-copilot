import SwiftUI
import UIKit

/// The call/text card on the car (`SendConfirmations`): a state of the voice card itself —
/// the person's photo, "Text Shabd Veyyakula: “hello”", and Send (Call) / Cancel as the card's
/// buttons — so it keeps listening for a spoken yes or no. Tested without CarPlay.
enum CarPlayConfirmText {
    struct Button: Equatable {
        let title: String
        let symbol: String
        let yes: Bool
    }

    /// One voice state per card (a new card is a new state).
    static func stateID(_ card: SendConfirmations.Card) -> String { "confirm-\(card.id)" }

    /// Longest first: CarPlay shows the first that fits.
    static func titles(_ card: SendConfirmations.Card) -> [String] {
        let name = card.title
        let first = card.name.flatMap { $0.split(separator: " ").first.map(String.init) } ?? name
        let names = first == name ? [name] : [name, first]
        let what = String(card.message.replacingOccurrences(of: "\n", with: " — ").prefix(80))
        let more = card.items.count > 1 ? " +\(card.items.count - 1)" : ""
        switch card.first.kind {
        case .call:
            let verb = card.first.via == "FaceTime" ? "FaceTime" : "Call"
            return names.map { "\(verb) \($0)?\(more)" }
        case .text, .email, .message:
            let verb = card.first.kind == .email ? "Email" : card.first.kind == .text ? "Text"
                : (card.first.via.isEmpty ? "Message" : card.first.via.capitalized)
            let said = what.isEmpty ? [] : names.map { "\(verb) \($0): “\(what)”\(more)" }
            return said + names.map { "\(verb) \($0)?\(more)" }
        }
    }

    static func buttons(_ card: SendConfirmations.Card) -> [Button] {
        [Button(title: card.actionTitle, symbol: card.actionSymbol, yes: true),
         Button(title: "Cancel", symbol: "xmark", yes: false)]
    }

    // MARK: Pictures

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

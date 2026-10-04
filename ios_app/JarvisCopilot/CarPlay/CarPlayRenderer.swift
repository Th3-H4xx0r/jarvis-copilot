import CarPlay
import SwiftUI
import UIKit

/// `CarPlaySection`/`CarPlayInfo` → Apple's templates. Taps are handed back as
/// the row's `CarPlayAction`; the renderer knows nothing about what they do.
@available(iOS 26.4, *)
@MainActor
enum CarPlayRenderer {
    typealias Handler = (CarPlayAction) -> Void

    static func sections(_ sections: [CarPlaySection], handler: @escaping Handler) -> [CPListSection] {
        // CarPlay shows only the first `maximumItemCount` items (across sections) and
        // `maximumSectionCount` sections; trim so the last rows (Load more) aren't
        // silently cut in the middle of a section.
        var budget = Int(CPListTemplate.maximumItemCount)
        var out: [CPListSection] = []
        for section in sections.prefix(Int(CPListTemplate.maximumSectionCount)) where budget > 0 {
            let rows = Array(section.rows.prefix(budget))
            budget -= rows.count
            out.append(CPListSection(items: rows.map { item($0, handler: handler) }, header: section.title, sectionIndexTitle: nil))
        }
        return out
    }

    static func item(_ row: CarPlayRow, handler: @escaping Handler) -> CPListItem {
        let pushes: Bool = { if case .push = row.action { return true } else { return false } }()
        let item = CPListItem(text: row.title, detailText: row.detail, image: image(for: row),
                              accessoryImage: row.checked ? UIImage(systemName: "checkmark") : nil,
                              accessoryType: pushes && !row.checked ? .disclosureIndicator : .none)
        item.isEnabled = row.enabled
        if row.action != .none {
            item.handler = { _, completion in
                handler(row.action)
                completion()
            }
        }
        if let clipID = row.clipThumbID {
            Task { @MainActor in
                guard let thumb = await DashcamThumbnails.shared.image(for: clipID) else { return }
                item.setImage(fit(thumb))
            }
        }
        return item
    }

    static func info(_ info: CarPlayInfo, handler: @escaping Handler) -> CPInformationTemplate {
        CPInformationTemplate(title: info.title, layout: .leading,
                              items: infoItems(info), actions: buttons(info, handler: handler))
    }

    static func update(_ template: CPInformationTemplate, with info: CarPlayInfo, handler: @escaping Handler) {
        template.items = infoItems(info)
        template.actions = buttons(info, handler: handler)
    }

    private static func infoItems(_ info: CarPlayInfo) -> [CPInformationItem] {
        info.items.map { CPInformationItem(title: $0.title, detail: $0.detail) }
    }

    private static func buttons(_ info: CarPlayInfo, handler: @escaping Handler) -> [CPTextButton] {
        info.actions.prefix(3).map { row in
            CPTextButton(title: row.title, textStyle: row.title.hasPrefix("Delete") ? .cancel : .normal) { _ in handler(row.action) }
        }
    }

    // MARK: Images

    static func image(for row: CarPlayRow) -> UIImage? {
        if row.orb { return jarvisOrbUIImage.map(fit) }
        guard let symbol = row.symbol, let base = UIImage(systemName: symbol) else { return nil }
        return base.withTintColor(color(row.tint ?? .accent), renderingMode: .alwaysOriginal)
    }

    static func color(_ tint: CarPlayTint) -> UIColor {
        switch tint {
        case .accent: return UIColor(JcTheme.accent)
        case .success: return UIColor(JcTheme.success)
        case .amber: return UIColor(JcTheme.amber)
        case .danger: return UIColor(JcTheme.danger)
        case .muted: return UIColor(JcTheme.muted)
        }
    }

    /// Scale an image into CarPlay's list-image box.
    static func fit(_ image: UIImage) -> UIImage {
        let box = CPListItem.maximumImageSize
        guard image.size.width > box.width || image.size.height > box.height, image.size.width > 0, image.size.height > 0 else { return image }
        let scale = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

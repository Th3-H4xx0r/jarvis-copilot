import SwiftUI
import UIKit

/// The chat composer's message field: a `UITextView`, because SwiftUI's
/// `TextField` gives no way to take a pasted image (`pasteDestination` is
/// iOS 27+). Grows from one line to `maxLines`, then scrolls — like the
/// `TextField(axis: .vertical)` it replaces.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines = 6
    /// Paste with an image or file on the clipboard hands its providers here;
    /// nil leaves Paste text-only.
    var onPasteAttachments: (([NSItemProvider]) -> Void)?

    private static let inset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(JcTheme.text)
        view.tintColor = UIColor(JcTheme.cyan)
        view.backgroundColor = .clear
        view.textContainerInset = Self.inset
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Message"
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteAttachments = onPasteAttachments
        if view.text != text { view.text = text }
        // First-responder changes can't happen mid-update; by the time this runs a
        // later update may have changed its mind, so read the newest value.
        if focused != view.isFirstResponder {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                let want = coordinator.parent.focused
                guard want != view.isFirstResponder else { return }
                if want { view.becomeFirstResponder() } else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = (view.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let cap = lineHeight * CGFloat(maxLines) + Self.inset.top + Self.inset.bottom
        let scrolls = fitting.height > cap
        if view.isScrollEnabled != scrolls {
            view.isScrollEnabled = scrolls
            // Back under the cap: drop the old offset or the first line stays clipped.
            if !scrolls { view.contentOffset = .zero }
        }
        return CGSize(width: width, height: min(fitting.height, cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.focused = false }
    }
}

/// A text view whose Paste also accepts images and files (see
/// ``PasteboardAttachments``); copied text pastes as usual.
final class PastingTextView: UITextView {
    var onPasteAttachments: (([NSItemProvider]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteAttachments != nil,
           PasteboardAttachments.mayAttach(types: UIPasteboard.general.types) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if let onPasteAttachments {
            let providers = PasteboardAttachments.attachable(board.itemProviders, text: board.string)
            if !providers.isEmpty {
                onPasteAttachments(providers)
                return
            }
        }
        super.paste(sender)
    }
}

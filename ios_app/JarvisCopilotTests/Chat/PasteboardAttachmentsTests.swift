import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import JarvisCopilot

/// Paste-to-attach in the chat composer: which clipboard mixes attach, and what
/// each pasted item turns into.
@MainActor
final class PasteboardAttachmentsTests: XCTestCase {

    private func provider(_ data: Data, _ type: UTType, name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: type) { done in done(data, nil); return nil }
        provider.suggestedName = name
        return provider
    }

    private func textProvider(_ text: String) -> NSItemProvider {
        NSItemProvider(object: text as NSString)
    }

    private var png: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: Which pastes attach

    func testACopiedImageAttaches() {
        let image = provider(png, .png)
        XCTAssertEqual(PasteboardAttachments.attachable([image], text: nil), [image])
    }

    func testCopiedTextPastesAsText() {
        XCTAssertTrue(PasteboardAttachments.attachable([textProvider("hello")], text: "hello").isEmpty)
    }

    func testRealTextBesideAPictureWins() {
        let mixed = [textProvider("Meeting notes"), provider(png, .png)]
        XCTAssertTrue(PasteboardAttachments.attachable(mixed, text: "Meeting notes").isEmpty)
    }

    func testALinkBesideAnImageStillAttachesTheImage() {
        let image = provider(png, .png)
        let link = "https://example.com/cat.png"
        XCTAssertEqual(PasteboardAttachments.attachable([textProvider(link), image], text: link), [image])
    }

    func testACopiedFileWhoseOnlyTextIsItsNameAttaches() {
        let pdf = provider(Data("%PDF-1.4".utf8), .pdf, name: "report.pdf")
        XCTAssertEqual(PasteboardAttachments.attachable([pdf], text: "report.pdf"), [pdf])
    }

    func testOnlyTheImagesAttachWhenImagesAndOtherDataAreCopiedTogether() {
        let image = provider(png, .png)
        let pdf = provider(Data("%PDF".utf8), .pdf)
        XCTAssertEqual(PasteboardAttachments.attachable([image, pdf], text: nil), [image])
    }

    func testTheEditMenuOffersPasteForImagesAndFilesButNotText() {
        XCTAssertTrue(PasteboardAttachments.mayAttach(types: [UTType.png.identifier]))
        XCTAssertTrue(PasteboardAttachments.mayAttach(types: [UTType.pdf.identifier]))
        XCTAssertFalse(PasteboardAttachments.mayAttach(types: [UTType.utf8PlainText.identifier]))
        XCTAssertFalse(PasteboardAttachments.mayAttach(types: [UTType.url.identifier, UTType.rtf.identifier]))
    }

    // MARK: What a pasted item becomes

    func testAPNGKeepsItsBytesAndExtension() async throws {
        let item = try await PasteboardAttachments.read(provider(png, .png), name: "pasted-1-0")
        XCTAssertEqual(item, .init(name: "pasted-1-0.png", data: png, isVideo: false))
    }

    func testAHEICImageBecomesAJPEGTheServerCanShowTheModel() async throws {
        let heic = try XCTUnwrap(UIImage(data: png)?.heicData())
        let item = try await PasteboardAttachments.read(provider(heic, .heic), name: "pasted-1-0")
        XCTAssertEqual(item.name, "pasted-1-0.jpg")
        XCTAssertEqual(Array(item.data.prefix(2)), [0xFF, 0xD8], "JPEG magic")
    }

    func testAFileKeepsItsOwnName() async throws {
        let bytes = Data("%PDF-1.4".utf8)
        let item = try await PasteboardAttachments.read(provider(bytes, .pdf, name: "report"), name: "pasted-1-0")
        XCTAssertEqual(item, .init(name: "report.pdf", data: bytes, isVideo: false))
    }

    func testPastedItemsLandInTheComposerStrip() async {
        let sink = Sink()
        await PasteboardAttachments.add([provider(png, .png)], to: sink)
        XCTAssertEqual(sink.added.count, 1)
        XCTAssertTrue(sink.added[0].isImage, "an image previews in the strip and goes to the model as vision")
        XCTAssertNil(sink.attachError)
    }
}

@MainActor
private final class Sink: AttachmentSink {
    var added: [PendingAttachment] = []
    var attachError: String?
    func addAttachment(_ attachment: PendingAttachment) { added.append(attachment) }
}

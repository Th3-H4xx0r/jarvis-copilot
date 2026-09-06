import XCTest
@testable import JarvisCopilot

/// Port of `test/chat_attachments_test.dart` — the upload fan-out for composer
/// attachments (a video also uploads its poster frame as a vision image).
final class ChatAttachmentsTests: XCTestCase {

    private func bytes(_ n: Int) -> Data { Data(repeating: 1, count: n) }

    func testAnImageAttachmentUploadsExactlyOnce() async {
        var calls: [String] = []
        let out = await uploadChatAttachments(
            [ChatPendingAttachment(name: "a.jpg", data: bytes(3), isImage: true)]
        ) { name, _ in
            calls.append(name)
            return ["filename": name, "path": "/u/\(name)", "is_image": true]
        }
        XCTAssertEqual(calls, ["a.jpg"])
        XCTAssertEqual(out.uploads.count, 1)
        XCTAssertEqual(out.uploads.first?["path"] as? String, "/u/a.jpg")
        XCTAssertTrue(out.failed.isEmpty)
    }

    func testAVideoUploadsTheFileAndAPosterImage() async {
        var calls: [String] = []
        let out = await uploadChatAttachments(
            [ChatPendingAttachment(name: "clip.mov", data: bytes(5), isVideo: true, posterData: bytes(2))]
        ) { name, _ in
            calls.append(name)
            return ["filename": name, "path": "/u/\(name)", "is_image": name.hasSuffix(".jpg")]
        }
        XCTAssertEqual(calls, ["clip.mov", "clip.mov.poster.jpg"])
        XCTAssertEqual(out.uploads.count, 2)
        XCTAssertEqual(out.uploads[1]["is_image"] as? Bool, true, "the poster is a vision image the model sees")
    }

    func testAVideoWithoutAPosterUploadsOnlyTheFile() async {
        let out = await uploadChatAttachments(
            [ChatPendingAttachment(name: "clip.mov", data: bytes(5), isVideo: true)]
        ) { name, _ in ["filename": name, "path": "/u/\(name)"] }
        XCTAssertEqual(out.uploads.count, 1)
        XCTAssertTrue(out.failed.isEmpty)
    }

    func testAFailedUploadIsSkippedAndTheRestStillSend() async {
        let out = await uploadChatAttachments([
            ChatPendingAttachment(name: "bad.png", data: bytes(1), isImage: true),
            ChatPendingAttachment(name: "ok.png", data: bytes(1), isImage: true),
        ]) { name, _ in
            if name == "bad.png" { throw APIError.badResponse("boom") }
            return ["filename": name, "path": "/u/\(name)"]
        }
        XCTAssertEqual(out.uploads.count, 1)
        XCTAssertEqual(out.uploads.first?["path"] as? String, "/u/ok.png")
        XCTAssertEqual(out.failed, ["bad.png"], "the caller has to be able to say the photo was left out")
    }

    /// A poster frame that fails does not lose the clip itself: the file landed,
    /// only the model's look at a frame is gone.
    func testAFailedPosterKeepsTheVideoItself() async {
        let out = await uploadChatAttachments(
            [ChatPendingAttachment(name: "clip.mov", data: bytes(5), isVideo: true, posterData: bytes(2))]
        ) { name, _ in
            if name.hasSuffix(".poster.jpg") { throw APIError.badResponse("boom") }
            return ["filename": name, "path": "/u/\(name)"]
        }
        XCTAssertEqual(out.uploads.count, 1)
        XCTAssertTrue(out.failed.isEmpty)
    }

    func testTheFailureLineNamesOneFileAndCountsMany() {
        XCTAssertNil(chatAttachmentFailureMessage([]))
        XCTAssertEqual(chatAttachmentFailureMessage(["a.png"]),
                       "Couldn't upload a.png — it was left out of this message.")
        XCTAssertEqual(chatAttachmentFailureMessage(["a.png", "b.png"]),
                       "Couldn't upload 2 attachments — they were left out of this message.")
    }

    func testAnEmptyUploadResultIsNotAdded() async {
        let out = await uploadChatAttachments([ChatPendingAttachment(name: "x", data: bytes(1))]) { _, _ in [:] }
        XCTAssertTrue(out.uploads.isEmpty)
        XCTAssertEqual(out.failed, ["x"], "an empty result is a failed upload, not a silent success")
    }

    func testPendingAttachmentDerivesItsThumbnailAndMessageAttachment() {
        let image = ChatPendingAttachment(name: "a.jpg", data: bytes(4), isImage: true)
        XCTAssertEqual(image.thumbnail, image.data, "an image previews with its own bytes")

        let video = ChatPendingAttachment(name: "v.mov", data: bytes(9), isVideo: true, posterData: bytes(2))
        XCTAssertEqual(video.thumbnail, video.posterData, "a video previews with its poster frame")
        XCTAssertEqual(video.size, 9)

        let file = ChatPendingAttachment(name: "n.pdf", data: bytes(1))
        XCTAssertNil(file.thumbnail, "a plain file falls back to a chip in the UI")
        XCTAssertEqual(file.messageAttachment.name, "n.pdf")
    }

    func testAVideoOverAHundredMegabytesIsRejectedBeforeItIsRead() {
        XCTAssertNil(ChatPendingAttachment.videoRejection(bytes: ChatPendingAttachment.maxVideoBytes))
        let tooBig = ChatPendingAttachment.videoRejection(bytes: ChatPendingAttachment.maxVideoBytes + 1)
        XCTAssertEqual(tooBig, "That video is too large (max 100 MB).")
    }

    /// The picker gates on the file's LENGTH before reading a byte, and the cap
    /// applies to plain files too (swift-correctness H14).
    func testTheSizeCapAppliesToPlainFilesAsWell() {
        let over = ChatPendingAttachment.maxVideoBytes + 1
        XCTAssertNil(ChatPendingAttachment.rejection(bytes: 10, isVideo: false))
        XCTAssertEqual(ChatPendingAttachment.rejection(bytes: over, isVideo: false),
                       "That file is too large (max 100 MB).")
        XCTAssertEqual(ChatPendingAttachment.rejection(bytes: over, isVideo: true),
                       "That video is too large (max 100 MB).")
    }

    func testLooksLikeAVideoByExtension() {
        for name in ["a.mov", "b.MP4", "c.m4v", "d.avi", "e.webm"] {
            XCTAssertTrue(ChatPendingAttachment.looksLikeVideo(name), name)
        }
        for name in ["a.png", "b.pdf", "c"] {
            XCTAssertFalse(ChatPendingAttachment.looksLikeVideo(name), name)
        }
    }

    func testLooksLikeAnImageByExtension() {
        for name in ["a.png", "b.JPG", "c.jpeg", "d.gif", "e.webp", "f.heic"] {
            XCTAssertTrue(ChatPendingAttachment.looksLikeImage(name), name)
        }
        for name in ["a.pdf", "b.mov", "c"] {
            XCTAssertFalse(ChatPendingAttachment.looksLikeImage(name), name)
        }
    }
}

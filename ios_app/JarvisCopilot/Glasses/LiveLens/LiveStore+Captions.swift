import Foundation

/// What Live captions need from Live Jarvis.
@MainActor
protocol LiveCaptionSource: AnyObject {
    var isCapturing: Bool { get }
    func captionSnapshot() -> LiveCaptionSnapshot
    /// Starts recording if it can; true when Live is recording afterwards.
    func startCapture() async -> Bool
    /// Fact-checks the conversation; the verdict to show, or nil.
    func runFactCheck() async -> (title: String, text: String)?
}

extension LiveStore: LiveCaptionSource {
    var isCapturing: Bool { capturing }

    func captionSnapshot() -> LiveCaptionSnapshot {
        let tail = transcript.segments.suffix(6).map {
            LiveCaptionSegment(seq: $0.seq, name: LiveFormat.speakerLabel(id: $0.speakerID, name: $0.speakerName),
                               text: $0.text, translation: $0.translation ?? "")
        }
        return LiveCaptionSnapshot(partial: partialText.isEmpty ? committingText : partialText,
                                   segments: Array(tail), session: liveSessionID)
    }

    func startCapture() async -> Bool {
        await start()
        return capturing
    }

    func runFactCheck() async -> (title: String, text: String)? {
        await factCheckConversation()
        guard let result = factCheck, !result.pending, !result.failed, !result.text.isEmpty else { return nil }
        let title = result.verdict.isEmpty ? "Fact-check" : "Fact-check · \(result.verdict.uppercased())"
        return (title, result.text)
    }
}

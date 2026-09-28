import Foundation

/// What Live captions need from Live Jarvis.
@MainActor
protocol LiveCaptionSource: AnyObject {
    var isCapturing: Bool { get }
    func captionSnapshot() -> LiveCaptionSnapshot
    /// Starts recording if it can; true when Live is recording afterwards.
    func startCapture() async -> Bool
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
}

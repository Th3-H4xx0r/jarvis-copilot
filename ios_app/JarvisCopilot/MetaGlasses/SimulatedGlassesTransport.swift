import Foundation

/// An in-memory `GlassesTransport` that stands in for the glasses + their far-end assistant, so
/// the whole `MetaGlassesSession` / `MetaGlassesDevice` lifecycle can be driven end-to-end with
/// NO hardware and NO AirShield crypto. This is a simplified, already-trusted session — it does
/// NOT reimplement the BLE L2CAP channel or the encrypted transport (those stay in
/// `MetaGlassesTransport`'s skeleton). DEBUG-only, and never referenced by production paths.
///
/// A test feeds scripted interactions through the `script*` methods and asserts on the recorded
/// outbound `sentFrames`.
///
/// Compiled into Release too: the Meta glasses page's "Run simulated glasses" drives a real Jarvis
/// voice turn through it (`MetaGlassesSimRunner`). Nothing constructs it outside that page and the
/// tests, and `MetaGlassesDevice.shared` keeps the real transport.
@MainActor
final class SimulatedGlassesTransport: GlassesTransport {
    private(set) var linkState: GlassesLinkState = .disconnected
    let inbound: AsyncStream<GlassesInboundEvent>
    private let continuation: AsyncStream<GlassesInboundEvent>.Continuation

    /// Every frame the session sent down, in order — the assertion surface for tests.
    private(set) var sentFrames: [GlassesFrame] = []

    /// Called with every frame the session sends down (the sim page's log).
    var onSent: ((GlassesFrame) -> Void)?

    private var streamTask: Task<Void, Never>?
    /// 40 ms of 16 kHz mono PCM16.
    static let frameBytes = 1_280

    /// Synthetic JPEG bytes a capture returns (valid SOI…EOI markers; not a decodable image).
    var cannedPhoto: Data = SimulatedGlassesTransport.makeSyntheticJPEG()

    init() {
        var cont: AsyncStream<GlassesInboundEvent>.Continuation!
        inbound = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    // MARK: GlassesTransport

    func connect() async throws {
        linkState = .ready   // already-trusted in-memory session
    }

    func send(_ frame: GlassesFrame) async throws {
        sentFrames.append(frame)
        onSent?(frame)
        // Act as the glasses camera: a capture request yields a still.
        if case .capturePhoto = frame {
            continuation.yield(.photo(cannedPhoto))
        }
    }

    func disconnect() async {
        stopStreaming()
        linkState = .disconnected
        continuation.finish()
    }

    // MARK: Scripting (the glasses / far-end assistant side)

    func emit(_ event: GlassesInboundEvent) { continuation.yield(event) }

    /// "Hey Jarvis" fired on the glasses.
    func scriptWake() { emit(.wake) }

    /// A spoken prompt: an on-device transcript plus an optional raw PCM follow-up (the task's
    /// "PCM or text stand-in").
    func scriptSpokenPrompt(transcript: String, pcm: Data? = nil) {
        if let pcm { emit(.userAudio(pcm)) }
        emit(.userTranscript(text: transcript, isFinal: true))
    }

    /// Stream spoken audio from the glasses mic the way real glasses do: `pcm` (16 kHz mono PCM16)
    /// in 40 ms frames at real-time pace, then silence — the mic stays open, and the voice engine's
    /// end-of-speech detector needs that quiet tail — until `stopStreaming()` or `silenceCap`.
    func streamSpokenAudio(_ pcm: Data, frameInterval: Duration = .milliseconds(40),
                           silenceCap: Duration = .seconds(15)) {
        stopStreaming()
        let frameBytes = Self.frameBytes
        streamTask = Task { [weak self] in
            var offset = pcm.startIndex
            while offset < pcm.endIndex {
                guard let self, !Task.isCancelled else { return }
                let end = min(offset + frameBytes, pcm.endIndex)
                self.emit(.userAudio(pcm.subdata(in: offset ..< end)))
                offset = end
                try? await Task.sleep(for: frameInterval)
            }
            let silence = Data(count: frameBytes)
            let clock = ContinuousClock()
            let quietFrom = clock.now
            while !Task.isCancelled, clock.now - quietFrom < silenceCap {
                guard let self else { return }
                self.emit(.userAudio(silence))
                try? await Task.sleep(for: frameInterval)
            }
        }
    }

    /// Stop the mic stream (idempotent).
    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// The assistant's canned reply, to be rendered back onto the lens.
    func scriptCannedReply(_ text: String) {
        emit(.assistantAnswer(text: text, isFinal: true))
    }

    /// A touchpad gesture.
    func scriptTouch(_ gesture: MetaTouchGesture) { emit(.touch(gesture)) }

    /// A runtime link-state change (e.g. a simulated drop).
    func scriptLinkState(_ state: GlassesLinkState) { emit(.linkState(state)) }

    static func makeSyntheticJPEG() -> Data {
        // SOI, APP0/JFIF header, a scrap of payload, EOI — enough to read as a JPEG by its magic.
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
                              0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
        bytes.append(contentsOf: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        bytes.append(contentsOf: [0xFF, 0xD9])
        return Data(bytes)
    }
}

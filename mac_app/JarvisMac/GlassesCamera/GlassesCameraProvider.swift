import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log
import Security

/// The Jarvis Glasses camera (a CoreMediaIO camera extension, WWDC22 "Create camera
/// extensions with Core Media IO"): one device with a SOURCE stream that FaceTime, Zoom and
/// Meet read and a SINK stream the Jarvis app writes the glasses' frames into. The extension
/// forwards the newest sink frame at 30 fps — letterboxed when the app picked landscape —
/// and draws the "Glasses not streaming" card whenever no fresh frame has come.
let glassesLog = Logger(subsystem: GlassesCameraSpec.extensionBundleID, category: "camera")

final class GlassesCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: GlassesCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = GlassesCameraDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Jarvis Glasses: couldn't add the camera: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let out = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { out.manufacturer = GlassesCameraSpec.manufacturer }
        return out
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// The camera: owns both streams, the 30 fps clock and the newest frame from the app.
/// Everything mutable lives on `queue`.
final class GlassesCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    static let clientsProperty = CMIOExtensionProperty(rawValue: GlassesCameraSpec.clientsPropertyName)

    private(set) var device: CMIOExtensionDevice!
    private var source: GlassesSourceStream!
    private var sink: GlassesSinkStream!
    private let queue = DispatchQueue(label: "jarvis.glasses.camera", qos: .userInteractive)

    // On `queue`:
    private var clients = 0
    private var timer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var consuming = false
    private var latest: CVPixelBuffer?
    private var latestAt: TimeInterval = 0
    private var outputs: [Output] = []

    /// One per offered format: its description, a pool for letterboxed frames and its card.
    private struct Output {
        let size: CGSize
        let format: CMFormatDescription
        let pool: CVPixelBufferPool?
        var placeholder: CVPixelBuffer?
    }

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: GlassesCameraSpec.name, deviceID: GlassesCameraSpec.deviceID,
                                     legacyDeviceID: nil, source: self)
        let frame = CMTime(value: 1, timescale: GlassesCameraSpec.fps)
        var formats: [CMIOExtensionStreamFormat] = []
        for size in GlassesCameraSpec.formats {
            guard let desc = GlassesCameraBuffers.format(size) else { continue }
            outputs.append(Output(size: size, format: desc, pool: GlassesCameraBuffers.pool(size), placeholder: nil))
            formats.append(CMIOExtensionStreamFormat(formatDescription: desc, maxFrameDuration: frame,
                                                     minFrameDuration: frame, validFrameDurations: nil))
        }
        source = GlassesSourceStream(formats: formats, owner: self)
        sink = GlassesSinkStream(format: formats[0], owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Jarvis Glasses: couldn't add the streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let out = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { out.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { out.model = GlassesCameraSpec.model }
        return out
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Who's watching (the source stream)

    var clientCount: Int { queue.sync { clients } }

    func sourceStarted() {
        queue.async {
            self.clients += 1
            self.announceClients()
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(GlassesCameraSpec.fps), leeway: .milliseconds(2))
            timer.setEventHandler { [weak device = self] in device?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func sourceStopped() {
        queue.async {
            self.clients = max(0, self.clients - 1)
            self.announceClients()
            guard self.clients == 0 else { return }
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// The app polls the property too; this just tells it sooner.
    private func announceClients() {
        let state = CMIOExtensionPropertyState<AnyObject>(value: "\(clients)" as NSString)
        source.stream.notifyPropertiesChanged([Self.clientsProperty: state])
    }

    // MARK: Frames in (the sink stream, from the Jarvis app)

    func sinkStarted(_ client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.consumeNext()
        }
    }

    func sinkStopped() {
        queue.async {
            self.sinkClient = nil
            self.latest = nil
        }
    }

    /// Asks the sink for the app's next frame (one request at a time; the clock retries).
    private func consumeNext() {
        guard let client = sinkClient, !consuming else { return }
        consuming = true
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, hasMore, _ in
            guard let self else { return }
            self.queue.async {
                self.consuming = false
                guard let buffer, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
                self.latest = pixels
                self.latestAt = ProcessInfo.processInfo.systemUptime
                let now = GlassesCameraBuffers.hostNow()
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now.nanoseconds))
                if hasMore { self.consumeNext() }
            }
        }
    }

    // MARK: Frames out (30 fps while an app watches)

    private func tick() {
        consumeNext()
        guard clients > 0, !outputs.isEmpty else { return }
        let index = min(max(0, source.activeFormatIndex), outputs.count - 1)
        let fresh = ProcessInfo.processInfo.systemUptime - latestAt < GlassesCameraSpec.staleAfter
        var pixels: CVPixelBuffer?
        if fresh, let latest {
            if GlassesFrameGeometry.size(of: latest) == outputs[index].size, GlassesFrameRenderer.isBGRA(latest) {
                pixels = latest
            } else if let out = GlassesCameraBuffers.buffer(from: outputs[index].pool),
                      GlassesFrameRenderer.render(latest, into: out) {
                pixels = out
            }
        }
        if pixels == nil { pixels = placeholder(index) }
        guard let pixels else { return }
        let now = GlassesCameraBuffers.hostNow()
        guard let sample = GlassesCameraBuffers.sample(pixels, format: outputs[index].format, at: now.time) else { return }
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now.nanoseconds)
    }

    /// The card for a format, drawn once and reused (it never changes).
    private func placeholder(_ index: Int) -> CVPixelBuffer? {
        if let ready = outputs[index].placeholder { return ready }
        guard let buffer = GlassesCameraBuffers.buffer(from: GlassesCameraBuffers.pool(outputs[index].size, minimum: 1))
        else { return nil }
        GlassesPlaceholder.render(into: buffer)
        outputs[index].placeholder = buffer
        return buffer
    }
}

/// What FaceTime, Zoom and Meet read: portrait 720×1280 or landscape 1280×720, 30 fps.
final class GlassesSourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private weak var owner: GlassesCameraDeviceSource?
    private let lock = NSLock()
    private var index = 0

    var activeFormatIndex: Int {
        get { lock.lock(); defer { lock.unlock() }; return index }
        set { lock.lock(); index = newValue; lock.unlock() }
    }

    init(formats: [CMIOExtensionStreamFormat], owner: GlassesCameraDeviceSource) {
        self.formats = formats
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: GlassesCameraSpec.name, streamID: GlassesCameraSpec.sourceStreamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, GlassesCameraDeviceSource.clientsProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let out = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { out.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { out.frameDuration = CMTime(value: 1, timescale: GlassesCameraSpec.fps) }
        if properties.contains(GlassesCameraDeviceSource.clientsProperty) {
            out.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: "\(owner?.clientCount ?? 0)" as NSString),
                                 forProperty: GlassesCameraDeviceSource.clientsProperty)
        }
        return out
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let wanted = streamProperties.activeFormatIndex, wanted >= 0, wanted < formats.count {
            activeFormatIndex = wanted
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { owner?.sourceStarted() }

    func stopStream() throws { owner?.sourceStopped() }
}

/// A sink client's code signature, looked up by its pid (GlassesSinkGate decides with it).
enum GlassesClientSignature {
    static func check(pid: pid_t) -> GlassesSinkGate.CodeCheck {
        guard pid > 0 else { return .unknown }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return .unknown }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(GlassesSinkGate.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .unknown }
        let status = SecCodeCheckValidity(code, [], requirement)
        if status == errSecSuccess { return .jarvis }
        // errSecCSReqFailed: a valid signature that isn't Jarvis's. Anything else: couldn't tell.
        return status == errSecCSReqFailed ? .other : .unknown
    }
}

/// Where the Jarvis app writes the glasses' frames (720×1280 BGRA). Only the Jarvis app may
/// feed it — no other app can put a picture into this camera.
final class GlassesSinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private weak var owner: GlassesCameraDeviceSource?
    private var client: CMIOExtensionClient?

    init(format: CMIOExtensionStreamFormat, owner: GlassesCameraDeviceSource) {
        formats = [format]
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: GlassesCameraSpec.name + " input", streamID: GlassesCameraSpec.sinkStreamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let out = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { out.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { out.frameDuration = CMTime(value: 1, timescale: GlassesCameraSpec.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { out.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { out.sinkBuffersRequiredForStartup = 1 }
        return out
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        let signingID = client.signingID
        let code = signingID == GlassesCameraSpec.appBundleID ? .jarvis : GlassesClientSignature.check(pid: client.pid)
        guard GlassesSinkGate.allows(signingID: signingID, code: code) else {
            glassesLog.error("refused a sink client: \(signingID ?? "nil", privacy: .public) pid \(client.pid) code \(String(describing: code), privacy: .public)")
            return false
        }
        if code == .unknown {
            glassesLog.notice("sink client pid \(client.pid) let in unverified: macOS gave no signing ID or signature")
        } else {
            glassesLog.info("sink client pid \(client.pid) is Jarvis")
        }
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { owner?.sinkStarted(client) }
    }

    func stopStream() throws { owner?.sinkStopped() }
}

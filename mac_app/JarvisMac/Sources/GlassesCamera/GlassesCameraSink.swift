import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// The app's end of the Jarvis Glasses camera, through CoreMediaIO: finds the extension's
/// device, reads how many apps are using it (the extension's 'jgcl' property on its source
/// stream) and writes frames into its sink stream — the supported way for an app to feed its
/// own camera extension (WWDC22 "Create camera extensions with Core Media IO").
final class GlassesCameraSink: @unchecked Sendable {
    struct Device: Equatable {
        let id: CMIOObjectID
        let source: CMIOStreamID
        let sink: CMIOStreamID
    }

    private let lock = NSLock()
    private var device: Device?
    private var queue: CMSimpleQueue?
    private let format = GlassesCameraBuffers.format(GlassesCameraSpec.sinkSize)

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return queue != nil
    }

    // MARK: Finding the camera

    /// The camera, when the extension is installed and running (approved in System Settings).
    static func findDevice() -> Device? {
        for id in objects(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices)) {
            let uid = string(id, UInt32(kCMIODevicePropertyDeviceUID))
            let name = string(id, UInt32(kCMIOObjectPropertyName))
            guard uid?.caseInsensitiveCompare(GlassesCameraSpec.deviceID.uuidString) == .orderedSame
                    || name == GlassesCameraSpec.name else { continue }
            let streams = objects(id, UInt32(kCMIODevicePropertyStreams))
            guard streams.count >= 2 else { continue }
            // Only the source stream carries the clients property; the other one is the sink.
            let source = streams.first { has($0, GlassesCameraSpec.clientsSelector) } ?? streams[0]
            guard let sink = streams.first(where: { $0 != source }) else { continue }
            return Device(id: id, source: source, sink: sink)
        }
        return nil
    }

    /// How many apps are using the camera (nil when the extension doesn't say).
    static func clients(on stream: CMIOStreamID) -> Int? {
        string(stream, GlassesCameraSpec.clientsSelector).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func has(_ object: CMIOObjectID, _ selector: UInt32) -> Bool {
        var addr = address(selector)
        return CMIOObjectHasProperty(object, &addr)
    }

    private static func objects(_ owner: CMIOObjectID, _ selector: UInt32) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(owner, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(owner, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    /// A CFString property (CoreMediaIO hands it over retained, like CoreAudio).
    private static func string(_ object: CMIOObjectID, _ selector: UInt32) -> String? {
        var addr = address(selector)
        guard CMIOObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, $0) }
        guard err == noErr, used > 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Writing frames

    /// Starts the sink stream (idempotent). False when the camera isn't there.
    @discardableResult
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if queue != nil { return true }
        guard let found = Self.findDevice() else { return false }
        var out: Unmanaged<CMSimpleQueue>?
        let err = CMIOStreamCopyBufferQueue(found.sink, { _, _, _ in }, nil, &out)
        // Unretained on purpose: one queue leaked per start beats an over-release.
        guard err == noErr, let queue = out?.takeUnretainedValue() else { return false }
        guard CMIODeviceStartStream(found.id, found.sink) == noErr else { return false }
        device = found
        self.queue = queue
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let device { CMIODeviceStopStream(device.id, device.sink) }
        device = nil
        queue = nil
    }

    /// One 720×1280 BGRA frame into the camera; dropped when the extension is behind.
    func write(_ pixels: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let queue, let format,
              CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue),
              let sample = GlassesCameraBuffers.sample(pixels, format: format, at: GlassesCameraBuffers.hostNow().time)
        else { return }
        let element = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: element.toOpaque()) != noErr { element.release() }
    }
}

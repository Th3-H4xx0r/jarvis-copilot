import AudioToolbox
import AVFoundation
import CoreAudio

/// Audio in whatever format it comes → 16 kHz mono Float32 samples. Fed from one
/// audio thread at a time.
/// After coucou's Resampler16k (github.com/Louis-CFM/coucou, MIT).
final class Resampler16k: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter.downmix = true
        self.converter = converter
        ratio = 16_000 / input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// One side of a call (your microphone, or what the Mac plays), kept in memory
/// only until it is transcribed: the stretch not transcribed yet, at most ~18 s.
/// Nothing is written to disk.
final class ChannelBuffer: @unchecked Sendable {
    static let sampleRate = 16_000.0

    private let lock = NSLock()
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var total = 0
    private var _level: Float = 0

    /// From the audio thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = Self.rms(samples[...])
        lock.withLock {
            pending.append(contentsOf: samples)
            total += samples.count
            _level = rms
        }
    }

    var level: Float { lock.withLock { _level } }

    /// The stretch ready to transcribe (NoteChunker decides), with where it starts
    /// in the recording. Silence is dropped.
    func takeChunk(force: Bool) -> (start: Double, samples: [Float])? {
        lock.withLock {
            let seconds = Double(pending.count) / Self.sampleRate
            let tail = Self.rms(pending.suffix(Int(Self.sampleRate / 2)))
            let decision = NoteChunker.decide(seconds: seconds, tailRMS: tail, rms: Self.rms(pending[...]), force: force)
            guard decision != .wait else { return nil }
            let chunk = (start: pendingStart, samples: pending)
            pendingStart = Double(total) / Self.sampleRate
            pending.removeAll(keepingCapacity: true)
            return decision == .cut ? chunk : nil
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// The microphone, as 16 kHz mono samples.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(sink: @escaping @Sendable ([Float]) -> Void) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: format) else { return false }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sink(resampler.convert(buffer))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays (the other people of a call, whatever the app),
/// through a Core Audio process tap (macOS 14.2+). macOS asks once for "System
/// Audio Recording". Nothing is muted: you keep hearing the call.
/// After coucou's SystemAudioTap (github.com/Louis-CFM/coucou, MIT).
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status): return "\(step) (\(status))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapList: UnsafeMutableAudioBufferListPointer?
    private let queue = DispatchQueue(label: "com.jarviscopilot.mac.notes.system", qos: .userInitiated)

    func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Jarvis note-taker"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("process tap", status) }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd),
              let resampler = Resampler16k(from: format) else {
            stop()
            throw TapError.failed("tap format", status)
        }

        let outputUID: String
        do { outputUID = try Self.defaultOutputUID() } catch { stop(); throw error }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jarvis note-taker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw TapError.failed("aggregate device", status)
        }
        aggregateID = device

        // The aggregate's input is the output device's own inputs (a headset's
        // microphone) if it has any, then the tap: the tap's buffers are the last ones.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let scratch = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        tapList = scratch
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var list = input
            if all.count > tapBuffers {
                for i in 0..<tapBuffers { scratch[i] = all[all.count - tapBuffers + i] }
                list = UnsafePointer(scratch.unsafePointer)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
            sink(resampler.convert(buffer))
        }
        guard status == noErr, let proc else {
            stop()
            throw TapError.failed("io proc", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw TapError.failed("start", status)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        if let tapList { free(tapList.unsafeMutablePointer) }
        tapList = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.failed("output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.failed("output device uid", status) }
        return uid as String
    }
}

import CoreAudio
import XCTest
@testable import JarvisVoiceUI

/// The real Mac microphone, prepared ahead and then started.
///
/// Opt-in with `JC_LIVE_MIC=1`: it needs microphone access for the test runner
/// and opens the default input for a moment. It proves the two things a mock
/// cannot: a prepared engine leaves the input device idle (no recording
/// indicator), and starting it delivers frames sooner than building one cold.
@MainActor
final class AudioInputPrepareLiveTests: XCTestCase {

    func testAPreparedMicStaysOffAndStartsFaster() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JC_LIVE_MIC"] == "1",
                          "set JC_LIVE_MIC=1 to run")

        let cold = try await msToFirstFrame(prepared: false)
        let warm = try await msToFirstFrame(prepared: true)
        print("mic first frame: cold=\(Int(cold))ms prepared=\(Int(warm))ms")
        XCTAssertLessThan(warm, cold, "preparing should make the first frame arrive sooner")
    }

    private func msToFirstFrame(prepared: Bool) async throws -> Double {
        let mic = DefaultAudioInput()
        if prepared {
            mic.prepare(sampleRate: 16000)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertFalse(Self.inputDeviceIsRunning, "a prepared mic must not be recording")
        }
        var first: Date?
        var peak = 0
        mic.onFrame = { data in
            if first == nil { first = Date() }
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int(sample))) }
            }
        }
        let tapped = Date()
        try await mic.start(sampleRate: 16000)
        while first == nil, Date().timeIntervalSince(tapped) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await mic.stop()
        let arrived = try XCTUnwrap(first, "no frames")
        XCTAssertGreaterThan(peak, 0, "frames should carry real signal, not digital zero")
        return arrived.timeIntervalSince(tapped) * 1000
    }

    private static var inputDeviceIsRunning: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return running != 0
    }
}

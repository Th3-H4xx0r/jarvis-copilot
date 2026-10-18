import Foundation

/// The voice log, kept on the phone across launches: a car test can be read
/// afterwards over the cable, where the live console capture dies whenever the
/// phone drops off. The lines are the diagnostics ring's and the CarPlay screen's
/// — privacy-safe, no transcripts, no audio. Bounded: past `maxBytes` the file
/// rolls over once into `voice.1.log`.
///
/// Pull it: `xcrun devicectl device copy from --device <udid> --domain-type
/// appDataContainer --domain-identifier com.jarviscopilot.jarviscopilotMobileAndIOS
/// --source Library/Caches/voice.log --destination voice.log`
final class VoiceLogFile: @unchecked Sendable {
    static let shared = VoiceLogFile(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        maxBytes: 1_000_000)

    let current: URL
    let previous: URL
    private let maxBytes: Int
    /// Every write happens here, off the main thread, in order.
    private let queue = DispatchQueue(label: "jc.voice-log", qos: .utility)
    /// The live file's size, read once and then counted (queue only).
    private var size: Int?

    init(directory: URL, maxBytes: Int) {
        current = directory.appendingPathComponent("voice.log")
        previous = directory.appendingPathComponent("voice.1.log")
        self.maxBytes = maxBytes
    }

    func append(_ line: String, at now: Date = Date()) {
        let data = Data((Self.dayStamp(now) + " " + line + "\n").utf8)
        queue.async { self.write(data) }
    }

    /// Returns once every line appended so far is on disk.
    func flush() { queue.sync {} }

    /// The ring's stamps carry only the time of day; the file is read days later.
    static func dayStamp(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func write(_ data: Data) {
        let files = FileManager.default
        var written = size ?? ((try? files.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0)
        if written > 0, written + data.count > maxBytes {
            try? files.removeItem(at: previous)
            try? files.moveItem(at: current, to: previous)
            written = 0
        }
        if !files.fileExists(atPath: current.path) { files.createFile(atPath: current.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: current) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            size = written + data.count
        } catch {
            size = nil   // re-read next time rather than trust a count that didn't land
        }
    }
}

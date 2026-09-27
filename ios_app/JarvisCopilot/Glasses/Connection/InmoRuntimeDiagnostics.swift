import Foundation

/// Bounded device diagnostics. Never stores audio, transcript, credentials or owner identity.
@MainActor enum InmoRuntimeDiagnostics {
    private static var lines: [String] = []
    static func note(_ line: String) {
        let entry = VoiceDiagnostics.stamp("GO3 " + line, at: Date())
        lines.append(entry)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        VoiceDiagnostics.mirror(entry)
        #if DEBUG
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: ["events": lines], options: [.prettyPrinted]) {
            try? data.write(to: root.appendingPathComponent("INMORuntimeDiagnostics.json"), options: .atomic)
        }
        #endif
    }
}

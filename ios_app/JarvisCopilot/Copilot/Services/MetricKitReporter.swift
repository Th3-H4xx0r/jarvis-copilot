import Foundation
import MetricKit
import os

/// Near-zero-cost field instrument. iOS aggregates energy / CPU / background-time
/// metrics on-device and delivers a payload roughly once every 24 h; we just log
/// it. It is the only way to confirm a battery fix on a real device, which
/// matters here because the app deliberately holds a silent audio session open.
///
/// Read the logs with:
/// `log show --predicate 'subsystem == "com.jarviscopilot.jarviscopilotMobileAndIOS.metrickit"' --last 48h`
///
/// Port of `ios/Runner/MetricKitReporter.swift`. Each day's numbers also go to
/// `/api/devices/mobile/energy`, so a fix can be checked without a cable.
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()
    private let log = Logger(subsystem: "com.jarviscopilot.jarviscopilotMobileAndIOS.metrickit", category: "payload")

    func register() {
        MXMetricManager.shared.add(self)
        log.info("MetricKit subscriber registered")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var report = EnergyReport(received: Date())
            if let cpu = payload.cpuMetrics {
                log.info("cpu.cumulativeCPUTime=\(cpu.cumulativeCPUTime.description, privacy: .public)")
                report.cpuSeconds = cpu.cumulativeCPUTime.converted(to: .seconds).value
            }
            if let run = payload.applicationTimeMetrics {
                log.info("""
                runtime fg=\(run.cumulativeForegroundTime.description, privacy: .public) \
                bg=\(run.cumulativeBackgroundTime.description, privacy: .public) \
                bgAudio=\(run.cumulativeBackgroundAudioTime.description, privacy: .public) \
                bgLocation=\(run.cumulativeBackgroundLocationTime.description, privacy: .public)
                """)
                report.foregroundSeconds = run.cumulativeForegroundTime.converted(to: .seconds).value
                report.backgroundSeconds = run.cumulativeBackgroundTime.converted(to: .seconds).value
                report.backgroundAudioSeconds = run.cumulativeBackgroundAudioTime.converted(to: .seconds).value
                report.backgroundLocationSeconds = run.cumulativeBackgroundLocationTime.converted(to: .seconds).value
            }
            // Kept so Settings can show it. `log show` needs a Mac, a cable and
            // root; the number that decides whether a battery change worked
            // should be readable on the phone that has the battery.
            report.save()
            // And to the server, so a battery change can be judged from there the next morning.
            Self.send(report)
            // No `privacy: .public` on the raw payloads: they carry the bundle's
            // signposts, launch times and (for diagnostics) crash call stacks,
            // and a `.public` string is readable by anything that can stream
            // this device's logs. The aggregate counters above are fine to
            // expose; the documents are not.
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                log.debug("payload=\(json)")
            }
        }
    }

    private static func send(_ report: EnergyReport) {
        let body: [String: Any] = [
            "received": ISO8601DateFormatter().string(from: report.received),
            "cpuSeconds": report.cpuSeconds,
            "foregroundSeconds": report.foregroundSeconds,
            "backgroundSeconds": report.backgroundSeconds,
            "backgroundAudioSeconds": report.backgroundAudioSeconds,
            "backgroundLocationSeconds": report.backgroundLocationSeconds,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ]
        Task { _ = try? await JarvisAPI.shared.post("/api/devices/mobile/energy", json: body) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                log.info("diagnostic=\(json)")
            }
        }
    }
}

import Foundation
import MetricKit
import os

/// Near-zero-cost field instrument. iOS aggregates energy/CPU/background-time
/// metrics on-device and delivers a payload roughly once every 24h; we just log
/// it. This is our only way to confirm battery fixes on real users' devices.
/// Read the logs with: `log show --predicate 'subsystem == "com.jarviscopilot.metrickit"' --last 48h`
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()
    private let log = Logger(subsystem: "com.jarviscopilot.metrickit", category: "payload")

    func register() {
        MXMetricManager.shared.add(self)
        log.info("MetricKit subscriber registered")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let cpu = payload.cpuMetrics {
                log.info("cpu.cumulativeCPUTime=\(cpu.cumulativeCPUTime.description, privacy: .public)")
            }
            if let run = payload.applicationTimeMetrics {
                log.info("""
                runtime fg=\(run.cumulativeForegroundTime.description, privacy: .public) \
                bg=\(run.cumulativeBackgroundTime.description, privacy: .public) \
                bgAudio=\(run.cumulativeBackgroundAudioTime.description, privacy: .public) \
                bgLocation=\(run.cumulativeBackgroundLocationTime.description, privacy: .public)
                """)
            }
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                log.debug("payload=\(json, privacy: .public)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                log.info("diagnostic=\(json, privacy: .public)")
            }
        }
    }
}

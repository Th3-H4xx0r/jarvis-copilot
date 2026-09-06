import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
import os
#endif

/// Near-zero-cost field instrument. iOS aggregates energy / CPU / background-time
/// metrics on-device and delivers a payload roughly once every 24 h; we just log
/// it. It is the only way to confirm a battery fix on a real device, which
/// matters here because the app deliberately holds a silent audio session open.
///
/// Read the logs with:
/// `log show --predicate 'subsystem == "com.jarviscopilot.jarviscopilotMobileAndIOS.metrickit"' --last 48h`
///
/// Port of `ios/Runner/MetricKitReporter.swift`. It never posted to the server
/// there and does not here — nothing to keep an endpoint for.
#if canImport(MetricKit) && os(iOS)
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitReporter()
    private let log = Logger(subsystem: "com.jarviscopilot.jarviscopilotMobileAndIOS.metrickit", category: "payload")

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

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                log.info("diagnostic=\(json)")
            }
        }
    }
}
#else
final class MetricKitReporter {
    static let shared = MetricKitReporter()
    func register() {}
}
#endif

#if DEBUG
import Foundation

/// Opt-in developer device trial. Private reconnect input is never embedded in the app.
@MainActor enum InmoDeviceTrial {
    private static var started = false
    static func runIfRequested() async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--inmo-device-trial") else { return }
        started = true
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let profile = root.appendingPathComponent("INMOReconnect.json")
        let output = root.appendingPathComponent("INMODeviceTrial.json")
        let session = InmoSession.shared
        var record: [String: Any] = ["started_at": ISO8601DateFormatter().string(from: Date())]
        let observer = session.addEventObserver { event in
            if case let .connectionChanged(state) = event { print("GO3 trial state: \(state.rawValue)") }
        }
        defer { session.removeEventObserver(observer) }
        do {
            if FileManager.default.fileExists(atPath: profile.path) {
                guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any],
                      let text = values["owner_base64"] as? String, let data = Data(base64Encoded: text), !data.isEmpty else {
                    throw InmoProtocolError.malformed("Invalid local reconnect profile")
                }
                try session.setOwnerIdentity(data)
                try FileManager.default.removeItem(at: profile)
                record["identity_imported_into_keychain"] = true
            }
            // Relaunching the app drops the BLE link, and the glasses can take
            // well over the single 20s connect deadline to come back. Retry the
            // connection for up to ~2 minutes before giving up.
            let connectDeadline = Date().addingTimeInterval(120)
            var connectAttempts = 0
            while !session.isReady, Date() < connectDeadline {
                connectAttempts += 1
                do { try await session.ensureConnected() }
                catch { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            record["connect_attempts"] = connectAttempts
            guard session.isReady else { throw InmoProtocolError.unavailable("GO3 did not reconnect within 120s after relaunch") }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            record["result"] = "ready"
            if ProcessInfo.processInfo.arguments.contains("--inmo-enable-ai") {
                await InmoAIChannel.shared.setEnabled(true)
                record["jarvis_ai_enabled"] = InmoAIChannel.shared.enabled
            }
            // ANCS notification spike: ask the firmware to consume iOS ANCS, then
            // record whether iOS considers the accessory authorised before/after.
            // Ground truth is whether real phone notifications appear on the lens.
            if ProcessInfo.processInfo.arguments.contains("--inmo-ancs-enable") {
                record["ancs_require_flag"] = ProcessInfo.processInfo.arguments.contains("--inmo-ancs-require")
                record["ancs_authorized_before"] = session.ancsAuthorized as Any? ?? NSNull()
                do {
                    try await session.send(InmoCommand.iosAncsEnable(true))
                    record["ancs_enable_sent"] = true
                } catch { record["ancs_enable_error"] = error.localizedDescription }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                record["ancs_authorized_after"] = session.ancsAuthorized as Any? ?? NSNull()
            }
            // Notification-card display test: push AppNotificationInfo cards over the
            // vendor MESSAGE_REMINDER channel and see if the lens draws them. Sends a
            // few, spaced out, so there's time to look.
            if ProcessInfo.processInfo.arguments.contains("--inmo-notif-test") {
                var sent = 0
                for i in 1...3 {
                    guard session.isReady else { break }
                    do {
                        try await session.send(InmoCommand.appNotification(title: "Jarvis", content: "Test notification \(i) — can you see this on the lens?"))
                        sent += 1
                    } catch { record["notif_test_error"] = error.localizedDescription }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                record["notif_test_sent"] = sent
            }
        } catch { record["result"] = "failed"; record["error"] = error.localizedDescription }
        record["state"] = session.state.rawValue
        record["services"] = session.discoveredServices
        record["battery"] = session.status.battery as Any? ?? NSNull()
        record["valid_frames"] = session.counters.validFrames
        record["completed_at"] = ISO8601DateFormatter().string(from: Date())
        do { try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { print("GO3 trial: failed to write diagnostic result") }
        print("GO3 trial result: \(record["result"] as? String ?? "unknown")")
    }
}
#endif

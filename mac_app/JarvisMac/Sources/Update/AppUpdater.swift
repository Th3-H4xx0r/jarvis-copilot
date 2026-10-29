import AppKit
import Observation
import SwiftUI

/// Store-style updates for this app: asks the server for a newer Mac build
/// (through jc-client's loopback proxy, like every other `/api` call here) on
/// launch, when the app becomes active, every 15 minutes and when the server
/// pushes `app_update`; offers it in a small panel; Install now downloads,
/// verifies and swaps it in with a detached helper, then quits.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    enum Phase: Equatable { case offered, downloading(Double), verifying, installing, failed(String) }

    private(set) var offer: MacAppUpdate?
    private(set) var phase: Phase = .offered

    @ObservationIgnored private var gate = AppUpdateGate()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var download: URLSessionDownloadTask?
    @ObservationIgnored private var progress: NSKeyValueObservation?
    @ObservationIgnored private var installing: Task<Void, Never>?

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.check(.activation) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: AppUpdateGate.snooze, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.check(.poll) }
        }
        check(.launch)
    }

    /// jc-client said hello (data nil: the server origin is known now) or the
    /// server pushed `app_update`.
    func signal(_ data: [String: Any]?) {
        if let data, J.s(data["platform"], "mac") != "mac" { return }
        check(data == nil ? .poll : .push)
    }

    func check(_ trigger: AppUpdateGate.Trigger) {
        guard !checking, panel == nil || phase == .offered else { return }
        checking = true
        Task {
            let update = await fetchLatest()
            checking = false
            if let update { present(update, trigger: trigger) }
        }
    }

    private func fetchLatest() async -> MacAppUpdate? {
        guard let origin = AppModel.shared.apiOrigin,
              let url = AppUpdateRules.latestURL(origin: origin, build: AppUpdateRules.ownBuild),
              let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let update = MacAppUpdate(json: json),
              AppUpdateRules.isNewer(update.build, than: AppUpdateRules.ownBuild) else { return nil }
        return update
    }

    private func present(_ update: MacAppUpdate, trigger: AppUpdateGate.Trigger) {
        if panel != nil {
            // Never two at once: a newer build replaces the one on screen.
            if phase == .offered, update.build > (offer?.build ?? 0) { offer = update }
            return
        }
        guard gate.shouldShow(build: update.build, trigger: trigger) else { return }
        offer = update
        phase = .offered
        showPanel()
    }

    // MARK: actions

    func later() {
        if let offer { gate.later(build: offer.build) }
        download?.cancel()
        closePanel()
    }

    func installNow() {
        // One install at a time: a second tap mustn't delete the first's download.
        guard installing == nil else { return }
        switch phase {
        case .offered, .failed: break
        default: return
        }
        phase = .downloading(0)
        installing = Task {
            defer { installing = nil }
            // The offer's link lives 10 minutes: ask again for a fresh one.
            guard let fresh = await fetchLatest() else {
                return fail("The update isn't available any more. Try again later.")
            }
            offer = fresh
            let parent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: parent) else {
                return fail("Jarvis can't write to \(parent), so it can't replace itself.")
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-update-\(fresh.build)")
            try? FileManager.default.removeItem(at: work)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = try await fetchZip(fresh.installURL, to: work.appendingPathComponent("Jarvis.zip"))
                phase = .verifying
                let app = try await Self.unpackAndVerify(zip: zip, in: work, build: fresh.build,
                                                         bundleID: Bundle.main.bundleIdentifier ?? "")
                phase = .installing
                try swap(to: app, work: work)
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.terminate(nil)
            } catch {
                // The helper owns the folder once it starts; until then it's ours.
                try? FileManager.default.removeItem(at: work)
                if !(error is CancellationError) { fail(error.localizedDescription) }
            }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }

    private func fetchZip(_ url: URL, to dest: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = URLSession.shared.downloadTask(with: URLRequest(url: url, timeoutInterval: 120)) { tmp, resp, error in
                if let error = error as? URLError, error.code == .cancelled { return cont.resume(throwing: CancellationError()) }
                if let error { return cont.resume(throwing: UpdateError("The download failed: \(error.localizedDescription)")) }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let tmp else {
                    return cont.resume(throwing: UpdateError(status == 403
                        ? "The download link expired. Try again." : "The download failed (HTTP \(status))."))
                }
                // The temp file goes when this handler returns.
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            progress = task.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if case .downloading = AppUpdater.shared.phase { AppUpdater.shared.phase = .downloading(f) }
                    }
                }
            }
            download = task
            task.resume()
        }
    }

    /// Unzip, then check the app is this one at the offered build and that it
    /// is signed like this one — before anything on disk is touched.
    private nonisolated static func unpackAndVerify(zip: URL, in work: URL, build: Int, bundleID: String) async throws -> URL {
        let out = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status == 0 else {
            throw UpdateError("The download isn't a valid zip.")
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The download has no app in it.")
        }
        if let problem = AppUpdateRules.problem(appAt: app, bundleID: bundleID, build: build) {
            throw UpdateError(problem)
        }
        if let problem = AppUpdateRules.signatureProblem(appAt: app) {
            throw UpdateError(problem)
        }
        return app
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Start the helper, detached (nohup, backgrounded) so it outlives this app.
    private func swap(to app: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        try AppUpdateRules.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let current = Bundle.main.bundlePath
        let exe = Bundle.main.executableURL?.lastPathComponent ?? "Jarvis"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \"$0\" \"$@\" >>\"$LOG\" 2>&1 &", script.path,
                       "\(ProcessInfo.processInfo.processIdentifier)", current, app.path,
                       work.appendingPathComponent("Jarvis-previous.app").path, exe, work.path]
        // The log sits outside the work folder, which the helper removes.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-update.log").path
        p.environment = ["LOG": log, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Couldn't start the installer.") }
    }

    // MARK: the panel

    private func showPanel() {
        let size = NSSize(width: 360, height: 10)
        let p = UpdatePanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: AppUpdateView(updater: self))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        p.setContentSize(host.fittingSize)
        // Top centre, under the menu bar and the island.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - 48))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func closePanel() {
        progress = nil
        download = nil
        panel?.orderOut(nil)
        panel = nil
        phase = .offered
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class UpdatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The pop-up: the live updater's state handed to `UpdateCard`.
private struct AppUpdateView: View {
    let updater: AppUpdater

    var body: some View {
        if let offer = updater.offer {
            UpdateCard(offer: offer, phase: updater.phase,
                       onInstall: { updater.installNow() }, onLater: { updater.later() })
        }
    }
}

/// The card in the phone's look: black glass with the accent glowing in from the top,
/// the app's icon, a status pill, what's new in a glass panel, one bright Install Now —
/// then the download's progress or what went wrong.
struct UpdateCard: View {
    let offer: MacAppUpdate
    var phase: AppUpdater.Phase = .offered
    var onInstall: () -> Void = {}
    var onLater: () -> Void = {}

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            if !items.isEmpty { whatsNew.padding(.top, 18) }
            status.padding(.top, 16)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(width: 380)
        .background {
            ZStack {
                Color.black
                Color.white.opacity(0.06)
                RadialGradient(colors: [JcAccent.color.opacity(0.28), .clear],
                               center: .top, startRadius: 0, endRadius: 220)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(LinearGradient(
            colors: [JcAccent.color.opacity(0.55), .white.opacity(0.1), .white.opacity(0.1)],
            startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .shadow(color: JcAccent.color.opacity(0.5), radius: 18)
            HStack(spacing: 6) {
                Circle().fill(JcAccent.color).frame(width: 6, height: 6)
                Text("Update available").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatStyle.text.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
            .padding(.top, 12)
            Text(offer.version.isEmpty ? "Jarvis" : "Jarvis \(offer.version)")
                .font(.system(size: 22, weight: .medium)).tracking(-0.5)
                .foregroundStyle(ChatStyle.text)
                .padding(.top, 9)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(ChatStyle.muted)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Build 263022206 · 6.6 MB" — the build as digits; Text's own interpolation
    /// would group it ("263,022,206").
    private var subtitle: String {
        var parts = ["Build " + String(offer.build)]
        if offer.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(offer.size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// One item per line, with the "•" / "-" the publisher typed taken off.
    private var items: [String] {
        offer.notes.split(whereSeparator: \.isNewline).map {
            var line = $0.trimmingCharacters(in: .whitespaces)
            if let first = line.first, "•-*".contains(first) { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WHAT\u{2019}S NEW").font(.system(size: 10, weight: .semibold)).tracking(1.1)
                .foregroundStyle(ChatStyle.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(JcAccent.color)
                            Text(item).font(.system(size: 13)).foregroundStyle(ChatStyle.text.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .offered:
            buttons(primary: "Install Now")
        case .downloading(let f):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: f).tint(JcAccent.color)
                Text(downloadLine(f)).font(.system(size: 11)).foregroundStyle(ChatStyle.muted)
            }
            .padding(.bottom, 4)
        case .verifying:
            line("Checking the download…")
        case .installing:
            line("Installing — Jarvis will reopen in a moment.")
        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(ChatStyle.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(primary: "Try Again")
            }
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(ChatStyle.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func buttons(primary: String) -> some View {
        VStack(spacing: 0) {
            Button(action: onInstall) {
                Label(primary, systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background {
                        Capsule().fill(LinearGradient(colors: [JcAccent.bright, JcAccent.color],
                                                      startPoint: .top, endPoint: .bottom))
                            .shadow(color: JcAccent.color.opacity(0.4), radius: 12, y: 3)
                    }
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            Button(action: onLater) {
                Text("Not Now").font(.system(size: 13, weight: .medium)).foregroundStyle(ChatStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.top, 4)
        }
    }

    private func downloadLine(_ f: Double) -> String {
        guard offer.size > 0 else { return "Downloading… \(Int(f * 100))%" }
        let mb = { (b: Double) in String(format: "%.0f", b / 1_048_576) }
        return "Downloading… \(mb(f * Double(offer.size))) of \(mb(Double(offer.size))) MB"
    }
}

import AppKit
import Foundation
import Observation

/// Mac screen sharing (Contract B of docs/superpowers/plans/2026-11-03-live-browser-and-screen.md).
///
/// A viewer (the iPhone app, the web UI) or a computer task asks the server for a
/// share; this service notices it — a push on the `screen_shares` topic over
/// jc-client's link, or its own list poll every 2 s — and runs a
/// `ScreenShareSession` for it: ScreenCaptureKit → WebRTC (the Mac answers each
/// viewer's offer), the viewer's mouse and keys back over the "input" data
/// channel, a recording of task shares uploaded when they end. Every request goes
/// through jc-client's loopback proxy (`AppModel.apiOrigin`), which adds this
/// Mac's paired session — the same way the island's chat talks to Jarvis.
@MainActor
@Observable
final class ScreenShareService {
    static let shared = ScreenShareService()

    /// Shares running on this Mac, by id.
    private(set) var sessions: [String: ScreenShareSession] = [:]
    /// Viewers connected across all shares.
    private(set) var viewers = 0
    /// Shares capturing this screen right now (the banner shows while > 0, watched or not).
    private(set) var capturing = 0
    /// One of them is a task share, so it is being recorded for the replay.
    private(set) var recording = false
    /// Screen Recording was refused: the banner says so until he fixes it or dismisses it.
    private(set) var permissionProblem: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollNow = false
    @ObservationIgnored private var polling = false
    /// Shares that already ended here, so a list that still says "live" for a beat
    /// doesn't restart them.
    @ObservationIgnored private var finished: Set<String> = []

    static let pollEvery: Duration = .seconds(2)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                for _ in 0..<20 {  // 2 s, cut short by a push
                    try? await Task.sleep(for: .milliseconds(100))
                    if self?.pollNow == true { break }
                }
                self?.pollNow = false
            }
        }
    }

    /// The server pushed `screen_shares`: look now instead of at the next tick.
    func poke() { pollNow = true }

    /// The banner's Stop: end every share from this side.
    func stopAll() {
        for s in sessions.values { s.stop(reason: nil) }
    }

    func dismissProblem() { permissionProblem = nil; ShareBanner.update() }

    private func poll() async {
        guard !polling, let origin = AppModel.shared.apiOrigin else { return }
        polling = true
        defer { polling = false }
        guard let obj = await ScreenAPI.getJSON(origin, "/api/screen/shares?active=1&from=mac", timeout: 10) else { return }
        let active = J.arr(obj["shares"]).filter { J.s($0["status"]) != "ended" }
        let ids = Set(active.map { J.s($0["id"]) })
        // Ended on the server (a viewer's Stop, the task finished): wind down here.
        for (id, s) in sessions where !ids.contains(id) {
            s.endedRemotely()
        }
        for share in active {
            let id = J.s(share["id"])
            guard !id.isEmpty, sessions[id] == nil, !finished.contains(id) else { continue }
            let s = ScreenShareSession(id: id, reason: J.s(share["reason"], "anytime"), origin: origin)
            s.onViewers = { [weak self] _ in self?.recount() }
            s.onFinished = { [weak self] id in
                self?.sessions[id] = nil
                self?.finished.insert(id)
                self?.recount()
            }
            s.onPermissionProblem = { [weak self] text in
                self?.permissionProblem = text
                ShareBanner.update()
            }
            sessions[id] = s
            s.start()
        }
        if finished.count > 200 { finished = Set(finished.suffix(50)) }
    }

    private func recount() {
        viewers = sessions.values.reduce(0) { $0 + $1.viewerCount }
        let live = sessions.values.filter(\.capturing)
        capturing = live.count
        recording = live.contains { $0.reason == "task" }
        ShareBanner.update()
    }
}

/// Small JSON helpers over the loopback proxy.
enum ScreenAPI {
    static func request(_ origin: String, _ path: String, method: String = "GET", json: [String: Any]? = nil,
                        timeout: TimeInterval = 20) -> URLRequest? {
        guard let url = URL(string: origin + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    static func getJSON(_ origin: String, _ path: String, timeout: TimeInterval = 20) async -> [String: Any]? {
        guard let req = request(origin, path, timeout: timeout) else { return nil }
        return await send(req)
    }

    @discardableResult
    static func postJSON(_ origin: String, _ path: String, _ body: [String: Any],
                         timeout: TimeInterval = 20) async -> [String: Any]? {
        guard let req = request(origin, path, method: "POST", json: body, timeout: timeout) else { return nil }
        return await send(req)
    }

    /// nil on a transport error; the server's JSON otherwise (with `_status`).
    static func send(_ req: URLRequest) async -> [String: Any]? {
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        obj["_status"] = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return obj
    }
}

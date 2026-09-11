import Foundation
import Observation

/// Page state for the Server logs screen: file + tail-size + severity filter,
/// line wrap, 5 s auto-refresh, and the copy-all payload.
///
/// Lines are rendered NEWEST FIRST (latest at the top), so `displayLines`
/// reverses the server's chronological tail.
@Observable
@MainActor
final class ServerLogsStore {
    private let api: ServerLogsAPI
    private let sleeper: Sleeper
    private let loadHandle = TaskHandle()
    private let timerHandle = TaskHandle()

    /// Tail sizes offered by the picker.
    static let tailOptions = [200, 500, 1000, 2000, 5000]

    private(set) var tail = ServerLogTail()
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    var file = "agent" { didSet { if file != oldValue { load() } } }
    var tailSize = 1000 { didSet { if tailSize != oldValue { load() } } }
    var filter: LogSeverityFilter = .all
    var wrapLines = true
    var autoRefresh = false { didSet { syncTimer() } }

    init(api: ServerLogsAPI = ServerLogsAPI(), sleeper: @escaping Sleeper = wallClockSleeper) {
        self.api = api
        self.sleeper = sleeper
    }

    deinit {
        loadHandle.cancel()
        timerHandle.cancel()
    }

    // MARK: Derived state

    /// Lines passing the severity filter, in the server's chronological order.
    var filteredLines: [String] {
        guard filter != .all else { return tail.lines }
        return tail.lines.filter { filter.admits(logSeverity($0)) }
    }

    /// What the list renders: newest first.
    var displayLines: [String] { filteredLines.reversed() }

    /// "42 of 1000 lines" — the footer counter.
    var countLabel: String { "\(filteredLines.count) of \(tail.lines.count) lines" }
    var isEmpty: Bool { hasLoaded && filteredLines.isEmpty }
    /// Text for the copy-all action (filtered, chronological).
    var copyText: String { filteredLines.joined(separator: "\n") }

    func severity(of line: String) -> LogSeverity { logSeverity(line) }

    // MARK: Loading

    func load() {
        isLoading = true
        errorMessage = nil
        loadHandle.replace(Task { [weak self] in await self?.refresh() })
    }

    func refresh() async {
        do {
            tail = try await api.tail(file: file, tail: tailSize)
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
        hasLoaded = true
    }

    /// Re-arm the live tail when the page is back on screen.
    func onAppear() { syncTimer() }

    func onDisappear() {
        timerHandle.cancel()
        loadHandle.cancel()
    }

    private func syncTimer() {
        guard autoRefresh else {
            timerHandle.cancel()
            return
        }
        // A tick is skipped while a load is still in flight, so requests can't
        // stack up when a fetch takes longer than the interval.
        timerHandle.poll(self, every: 5, sleeper: sleeper) { store in
            if !store.isLoading { await store.refresh() }
        }
    }
}

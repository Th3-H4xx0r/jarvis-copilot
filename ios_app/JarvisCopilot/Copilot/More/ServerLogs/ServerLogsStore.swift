import Foundation
import Observation

/// Page state for the Server logs screen: file + tail-size + severity filter,
/// line wrap, 5 s auto-refresh, and the copy-all payload.
///
/// Lines are rendered NEWEST FIRST (latest at the top), which is what the
/// Flutter page did — so `displayLines` reverses the server's chronological tail.
@Observable
@MainActor
final class ServerLogsStore {
    private let api: ServerLogsAPI
    private let refreshInterval: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
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

    init(api: ServerLogsAPI = ServerLogsAPI(),
         refreshInterval: TimeInterval = 5,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.refreshInterval = refreshInterval
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
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

    func onDisappear() {
        timerHandle.cancel()
        loadHandle.cancel()
    }

    /// Await the in-flight auto-refresh tick (tests).
    func waitForAutoRefresh() async { await timerHandle.wait() }

    private func syncTimer() {
        guard autoRefresh else {
            timerHandle.cancel()
            return
        }
        guard !timerHandle.isActive else { return }
        timerHandle.replace(Task { [weak self] in
            // Guard inside the loop: hoisted, the auto-refresh ticker pins the
            // store and `deinit` never runs.
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleeper(self.refreshInterval)
                if Task.isCancelled { return }
                // Skip this tick if a load is still in flight, so requests can't
                // stack up when a fetch takes longer than the interval.
                if self.isLoading { continue }
                await self.refresh()
            }
        })
    }
}

import Foundation

/// A cancellable slot for an in-flight `Task`, and the polling loop built on it.
///
/// Lived in `More/MoreSupport.swift` and was never about the More screen: the
/// chat store, the voice store, the cron store and the log store all hold one,
/// which is why it sits in `Core` with the other infrastructure. Moving it also
/// let the Mac voice client take the utility without taking the More layer.

// MARK: - Cancellable task slot

/// A cancellable slot for one in-flight `Task`.
///
/// `@MainActor` stores need to cancel their work from `deinit`, which is
/// *nonisolated* — so the task can't live in a plain `var`. An immutable
/// `Sendable let` is reachable from any context, hence this tiny box.
/// Replacing the task cancels whatever it displaced.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Bumped on every `replace`, so a finishing task only clears the slot when
    /// it is still the one the slot holds.
    private var generation = 0

    /// Install a new task, cancelling the one it replaces.
    func replace(_ new: Task<Void, Never>?) {
        lock.lock()
        generation += 1
        let id = generation
        let previous = task
        task = new
        lock.unlock()
        previous?.cancel()
        guard let new else { return }
        // Clear the slot when the task ends on its OWN (a stream that closed, a
        // loop that returned) rather than only when something replaces it.
        // Without this `isActive` stays true forever after a poller's loop
        // exits, and every `guard !handle.isActive else { return }` re-arm —
        // `ChatStore.setListPolling`, `CronsStore.syncPoll`,
        // `ServerLogsStore.syncTimer` — wedges permanently.
        Task { [weak self] in
            await new.value
            self?.clear(generation: id)
        }
    }

    /// Drop the task this generation installed, if it is still the current one.
    private func clear(generation id: Int) {
        lock.lock()
        if id == generation { task = nil }
        lock.unlock()
    }

    func cancel() { replace(nil) }

    var current: Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return task
    }

    var isActive: Bool { current != nil }

    /// Await the in-flight task, if any (tests, and scene-phase handoffs).
    func wait() async { await current?.value }
}

// MARK: - Sleeping and polling

/// Sleeps for a number of seconds. Stores that poll or debounce take one so
/// tests can resume it instantly.
typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

let wallClockSleeper: Sleeper = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

extension TaskHandle {
    /// Runs `tick` every `interval` seconds until cancelled or `owner` is gone;
    /// a no-op while a poll is already running. The owner is held weakly and
    /// re-resolved each tick — holding it strongly would pin it for as long as
    /// the poll runs, so the `deinit` that cancels the poll would never run.
    @MainActor
    func poll<Owner: AnyObject>(_ owner: Owner, every interval: TimeInterval, sleeper: @escaping Sleeper,
                                _ tick: @escaping @Sendable @MainActor (Owner) async -> Void) {
        guard !isActive else { return }
        replace(Task { @MainActor [weak owner] in
            while !Task.isCancelled, owner != nil {
                try? await sleeper(interval)
                guard !Task.isCancelled, let owner else { return }
                await tick(owner)
            }
        })
    }
}

import Foundation
import XCTest
@testable import JarvisCopilot

/// `TaskHandle` (`Copilot/More/MoreSupport.swift`) — the cancellable slot every
/// store's poller lives in.
///
/// The slot has to empty itself when its task ends on its OWN, not only when
/// something replaces it: every re-arm in the app is spelled
/// `guard !handle.isActive else { return }`, so a handle that stays "active"
/// after its loop returned wedges that poller for the life of the screen
/// (`ChatStore.setListPolling`, `CronsStore.syncPoll`, `ServerLogsStore.syncTimer`).
final class TaskHandleTests: XCTestCase {

    /// Spin until `condition` holds — the slot is cleared by a watcher task, so
    /// it becomes true a hop after the work finishes, not synchronously.
    private func waitUntilHandle(_ condition: @escaping () -> Bool,
                                 timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testAFinishedTaskClearsTheSlot() async {
        let handle = TaskHandle()
        handle.replace(Task { })
        await handle.wait()
        await waitUntilHandle { !handle.isActive }
        XCTAssertFalse(handle.isActive, "a completed task must not keep the slot armed")
        XCTAssertNil(handle.current)
    }

    func testARunningTaskKeepsTheSlotArmed() async {
        let handle = TaskHandle()
        let started = expectation(description: "started")
        handle.replace(Task {
            started.fulfill()
            try? await Task.sleep(nanoseconds: 400_000_000)
        })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(handle.isActive)
        handle.cancel()
    }

    /// The re-arm pattern every store uses. Before the fix the second arm was
    /// dropped, because the first task's slot never emptied.
    func testAPollerCanBeReArmedAfterItsLoopEnds() async {
        let handle = TaskHandle()
        var runs = 0

        func arm() {
            guard !handle.isActive else { return }
            handle.replace(Task { @MainActor in runs += 1 })
        }

        arm()
        await handle.wait()
        await waitUntilHandle { !handle.isActive }
        arm()
        await handle.wait()
        await waitUntilHandle { runs == 2 }

        XCTAssertEqual(runs, 2, "the second arm must not be swallowed by a stale slot")
    }

    /// A task that finishes AFTER it has been replaced must not clear the slot
    /// its successor now owns.
    func testAFinishedTaskDoesNotClearItsSuccessor() async {
        let handle = TaskHandle()
        let first = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000) }
        handle.replace(first)
        let running = expectation(description: "second running")
        handle.replace(Task {
            running.fulfill()
            try? await Task.sleep(nanoseconds: 500_000_000)
        })
        await fulfillment(of: [running], timeout: 2)
        _ = await first.value                     // the displaced (cancelled) task ends

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(handle.isActive, "the successor is still running")
        handle.cancel()
    }

    func testReplacingCancelsWhatItDisplaced() async {
        let handle = TaskHandle()
        let cancelled = expectation(description: "cancelled")
        handle.replace(Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { cancelled.fulfill() }
        })
        handle.replace(Task { })
        await fulfillment(of: [cancelled], timeout: 2)
    }
}

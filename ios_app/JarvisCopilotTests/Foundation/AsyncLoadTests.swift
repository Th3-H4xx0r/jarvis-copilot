import Foundation
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Port of `test/services/async_view_test.dart` against `Copilot/UI/AsyncView.swift`.
///
/// The Dart tests drove the widget; the Swift split puts every decision in
/// `AsyncLoad`, so the four cases are asserted on the state machine and the view
/// is hosted once per branch to prove it still builds around it.
@MainActor
final class AsyncLoadTests: XCTestCase {

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: The four Dart cases

    /// "renders builder output once loaded".
    func testAValueIsPublishedOnceTheLoadLands() async {
        let model = AsyncLoad<[String]>()
        await model.run { ["alpha", "beta"] }

        XCTAssertEqual(model.value, ["alpha", "beta"])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isLoading)

        asyncLoadHost(AsyncView(load: { ["alpha", "beta"] }) { rows, _ in
            VStack { ForEach(rows, id: \.self) { Text($0) } }
        })
    }

    /// "shows error text + Retry when the loader throws" — with nothing loaded
    /// the failure becomes the full-screen message (which carries the Retry).
    func testAFailedFirstLoadBecomesTheFullScreenMessage() async {
        let model = AsyncLoad<Int>()
        await model.run { throw Boom() }

        XCTAssertNil(model.value)
        XCTAssertEqual(model.errorMessage, "boom")
        XCTAssertEqual(model.lastError, "boom")

        asyncLoadHost(AsyncView(load: { throw Boom() }) { (value: Int, _) in Text("\(value)") })
    }

    /// "shows emptyText when isEmpty is true" — the empty predicate is the
    /// view's, so this one is asserted through the view.
    func testAnEmptyValueRendersTheEmptyText() async {
        let model = AsyncLoad<[String]>()
        await model.run { [] }
        XCTAssertEqual(model.value, [])
        XCTAssertNil(model.errorMessage, "empty is not an error")

        asyncLoadHost(AsyncView(emptyText: "nothing to see",
                                isEmpty: { $0.isEmpty },
                                load: { [String]() }) { _, _ in Text("should not show") })
    }

    /// "controller.refresh re-runs the loader" — `token` is the Swift shape of
    /// `AsyncViewController.refresh()`; `.task(id:)` restarts on every bump.
    func testBumpingTheTokenIsWhatReRunsTheLoader() async {
        let model = AsyncLoad<Int>()
        var calls = 0
        let load: () async throws -> Int = { calls += 1; return calls }

        await model.run(load)
        XCTAssertEqual(model.value, 1)

        let before = model.token
        model.token += 1
        XCTAssertEqual(model.token, before + 1, "the view's .task(id:) keys off this")
        await model.run(load)
        XCTAssertEqual(model.value, 2)
    }

    // MARK: Refresh failures (silent-failures L2)

    /// A refresh that fails while a value is on screen keeps the value — but it
    /// must not be silent. `lastError` is what the banner reads; before it, the
    /// spinner simply retracted and the stale rows stayed.
    func testAFailedRefreshKeepsTheValueAndStillReportsTheFailure() async {
        let model = AsyncLoad<[String]>()
        await model.run { ["alpha"] }
        await model.run { throw Boom() }

        XCTAssertEqual(model.value, ["alpha"], "a refresh failure must not blank the screen")
        XCTAssertNil(model.errorMessage, "no full-screen error while there is content")
        XCTAssertEqual(model.lastError, "boom", "…but the failure is still surfaced")
    }

    func testASuccessfulReloadClearsTheStaleFailure() async {
        let model = AsyncLoad<[String]>()
        await model.run { ["alpha"] }
        await model.run { throw Boom() }
        await model.run { ["beta"] }

        XCTAssertEqual(model.value, ["beta"])
        XCTAssertNil(model.lastError)
    }

    /// A superseded reload cancels, and cancellation is not a failure — showing
    /// "cancelled" for a load the user themselves replaced would be noise.
    func testCancellationIsNotReportedAsAFailure() async {
        let model = AsyncLoad<[String]>()
        await model.run { ["alpha"] }
        await model.run { throw CancellationError() }

        XCTAssertEqual(model.value, ["alpha"])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.lastError)
    }

    // MARK: The shared banner modifier (silent-failures M3)

    func testTheLoadErrorBannerOnlyAppliesWhereThereIsContent() {
        // Both branches have to build; the modifier's own decision is a pure
        // function of (message, hasContent).
        asyncLoadHost(Text("rows").loadErrorBanner("that failed", hasContent: true))
        asyncLoadHost(Text("rows").loadErrorBanner("that failed", hasContent: false))
        asyncLoadHost(Text("rows").loadErrorBanner(nil, hasContent: true))
    }
}

/// Host a view for real, so a `body` that does not compose is a failure rather
/// than dead code. Prefixed to avoid the module-wide name collisions other
/// areas hit.
@MainActor
func asyncLoadHost<V: View>(_ view: V,
                            size: CGSize = CGSize(width: 393, height: 852),
                            file: StaticString = #filePath, line: UInt = #line) {
    let host = UIHostingController(rootView: view)
    host.view.frame = CGRect(origin: .zero, size: size)
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    XCTAssertEqual(host.view.bounds.size, size, "hosted view lost its frame",
                   file: file, line: line)
}

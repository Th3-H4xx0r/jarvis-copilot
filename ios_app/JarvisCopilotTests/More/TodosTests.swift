import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/todos_test.dart`, case for case.
final class TodosTests: XCTestCase {

    /// A `role: 'tool'` message whose JSON content carries `todos`.
    private func toolMessage(_ todos: [JSONObject]) -> JSONObject {
        let data = try! JSONSerialization.data(withJSONObject: ["todos": todos])
        return ["role": "tool", "content": String(decoding: data, as: UTF8.self)]
    }

    // MARK: extractTodos

    func testReturnsTheTodosFromASingleToolMessage() {
        let todos: [JSONObject] = [
            ["id": "1", "content": "Write the code", "status": "in_progress"],
            ["id": "2", "content": "Ship it", "status": "pending"],
        ]
        let messages: [Any] = [
            ["role": "user", "content": "do the thing"] as JSONObject,
            toolMessage(todos),
            ["role": "assistant", "content": "on it"] as JSONObject,
        ]
        let out = TodosParser.extractTodos(messages)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].content, "Write the code")
        XCTAssertEqual(out[0].status, "in_progress")
        XCTAssertEqual(out[1].status, "pending")
    }

    func testReturnsTheNewestTodosMessageWhenSeveralArePresent() {
        let older: [JSONObject] = [["id": "1", "content": "old task", "status": "pending"]]
        let newer: [JSONObject] = [
            ["id": "1", "content": "old task", "status": "completed"],
            ["id": "2", "content": "new task", "status": "in_progress"],
        ]
        let messages: [Any] = [
            toolMessage(older),
            ["role": "assistant", "content": "progress"] as JSONObject,
            toolMessage(newer),
            ["role": "assistant", "content": "more progress"] as JSONObject,
        ]
        let out = TodosParser.extractTodos(messages)
        // The newest-first scan must land on `newer`, not `older`.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].status, "completed")
        XCTAssertEqual(out[1].content, "new task")
    }

    func testReturnsEmptyWhenNoMessageCarriesATodosList() {
        let resultJSON = try! JSONSerialization.data(withJSONObject: ["result": "ok"])
        let messages: [Any] = [
            ["role": "user", "content": "hello"] as JSONObject,
            ["role": "assistant", "content": "hi there"] as JSONObject,
            // A tool message with no todos in its JSON is ignored.
            ["role": "tool", "content": String(decoding: resultJSON, as: UTF8.self)] as JSONObject,
        ]
        XCTAssertTrue(TodosParser.extractTodos(messages).isEmpty)
    }

    func testEmptyMessagesListReturnsEmpty() {
        XCTAssertTrue(TodosParser.extractTodos([]).isEmpty)
    }

    func testAnEmptyTodosArrayIsTreatedAsNoListAndKeepsScanning() {
        let messages: [Any] = [
            toolMessage([["id": "1", "content": "real task", "status": "pending"]]),
            // A later tool message with an empty todos array must NOT shadow the
            // real list above (mirrors panels.js: requires a non-empty array).
            toolMessage([]),
        ]
        let out = TodosParser.extractTodos(messages)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].content, "real task")
    }

    func testToleratesAlreadyDecodedMapContent() {
        let messages: [Any] = [
            ["role": "tool",
             "content": ["todos": [["id": "1", "content": "decoded task", "status": "completed"]]]] as JSONObject,
        ]
        let out = TodosParser.extractTodos(messages)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].content, "decoded task")
    }

    // MARK: Status ranking + styles (todos_page logic)

    func testStatusRankSortsActiveWorkFirst() {
        let items = [
            TodoItem(id: "a", content: "done", status: "completed"),
            TodoItem(id: "b", content: "cancelled", status: "cancelled"),
            TodoItem(id: "c", content: "doing", status: "in_progress"),
            TodoItem(id: "d", content: "next", status: "pending"),
        ]
        XCTAssertEqual(TodosStore.sorted(items).map(\.id), ["c", "d", "a", "b"])
    }

    func testUnknownStatusRanksWithPendingAndSortIsStable() {
        let items = [
            TodoItem(id: "a", content: "?", status: "weird"),
            TodoItem(id: "b", content: "next", status: "pending"),
            TodoItem(id: "c", content: "doing", status: "in_progress"),
        ]
        XCTAssertEqual(TodosStore.sorted(items).map(\.id), ["c", "a", "b"])
    }

    func testStyleMirrorsPanelsJS() {
        XCTAssertEqual(TodoStatusStyle.of("completed").label, "COMPLETED")
        XCTAssertTrue(TodoStatusStyle.of("completed").strikethrough)
        XCTAssertEqual(TodoStatusStyle.of("in_progress").label, "IN PROGRESS")
        XCTAssertTrue(TodoStatusStyle.of("in_progress").spin)
        XCTAssertEqual(TodoStatusStyle.of("cancelled").label, "CANCELLED")
        XCTAssertTrue(TodoStatusStyle.of("cancelled").strikethrough)
        XCTAssertEqual(TodoStatusStyle.of("pending").label, "PENDING")
        XCTAssertEqual(TodoStatusStyle.of("whatever").label, "PENDING")
    }

    func testMissingStatusDefaultsToPending() {
        let item = TodoItem(json: ["id": "1", "content": "x"])
        XCTAssertEqual(item.status, "pending")
    }

    // MARK: API requests

    func testCurrentSessionResolvesNewestSessionThenScansItsMessages() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["sessions": [
            ["session_id": "old", "updated_at": 100],
            ["session_id": "new", "updated_at": 900],
        ]])
        let toolContent = try! JSONSerialization.data(withJSONObject: [
            "todos": [["id": "1", "content": "from session", "status": "pending"]],
        ])
        transport.enqueue(json: ["session": ["messages": [
            ["role": "tool", "content": String(decoding: toolContent, as: UTF8.self)],
        ]]])

        let todos = try await TodosAPI(api: api).currentSession()

        XCTAssertEqual(transport.method(0), "GET")
        XCTAssertEqual(transport.path(0), "/api/sessions")
        XCTAssertEqual(transport.query(0), [:])
        XCTAssertEqual(transport.method(1), "GET")
        XCTAssertEqual(transport.path(1), "/api/session")
        XCTAssertEqual(transport.query(1),
                       ["session_id": "new", "messages": "1", "resolve_model": "0"])
        XCTAssertEqual(todos.map(\.content), ["from session"])
    }

    func testCurrentSessionReturnsEmptyWhenThereAreNoSessions() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["sessions": []])
        let todos = try await TodosAPI(api: api).currentSession()
        XCTAssertTrue(todos.isEmpty)
        // No second request — nothing to fetch messages for.
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testActiveSessionIDFallsBackToLastMessageAtAndBareIDKey() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["sessions": [
            ["id": "a", "last_message_at": 5],
            ["id": "b", "last_message_at": 50],
        ]])
        let id = try await TodosAPI(api: api).activeSessionID()
        XCTAssertEqual(id, "b")
    }

    // MARK: Store

    @MainActor
    func testStoreSortsAndCountsProgress() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": [["session_id": "s1", "updated_at": 1]]])
        let content = try! JSONSerialization.data(withJSONObject: ["todos": [
            ["id": "1", "content": "done", "status": "completed"],
            ["id": "2", "content": "doing", "status": "in_progress"],
            ["id": "3", "content": "next", "status": "pending"],
        ]])
        transport.route("/api/session", json: ["session": ["messages": [
            ["role": "tool", "content": String(decoding: content, as: UTF8.self)],
        ]]])

        let store = TodosStore(api: TodosAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.todos.map(\.id), ["2", "3", "1"])
        XCTAssertEqual(store.doneCount, 1)
        XCTAssertEqual(store.totalCount, 3)
        XCTAssertEqual(store.progressLabel, "1 / 3 done")
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStoreSurfacesAnError() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "nope"], status: 500)
        let store = TodosStore(api: TodosAPI(api: api))
        await store.refresh()
        XCTAssertEqual(store.errorMessage, "nope")
        XCTAssertTrue(store.todos.isEmpty)
    }
}

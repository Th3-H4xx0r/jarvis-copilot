import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/kanban_test.dart`, case for case, plus the
/// endpoint and store behaviour from `kanban_page.dart`.
final class KanbanTests: XCTestCase {

    // MARK: kanbanTaskId

    func testReadsTheIDField() {
        XCTAssertEqual(Kanban.taskID(["id": "t_1", "title": "A"]), "t_1")
    }

    func testFallsBackToTaskID() {
        XCTAssertEqual(Kanban.taskID(["task_id": "t_2"]), "t_2")
    }

    func testPrefersIDOverTaskIDWhenBothPresent() {
        XCTAssertEqual(Kanban.taskID(["id": "t_a", "task_id": "t_b"]), "t_a")
    }

    func testReturnsEmptyStringWhenNeitherKeyIsPresent() {
        XCTAssertEqual(Kanban.taskID(["title": "no id"]), "")
    }

    func testStringifiesNonStringIDs() {
        XCTAssertEqual(Kanban.taskID(["id": 42]), "42")
    }

    // MARK: kanbanTaskColumn

    func testReadsStatusTheBridgeColumnKey() {
        XCTAssertEqual(Kanban.taskColumn(["status": "ready"]), "ready")
    }

    func testToleratesAColumnAlias() {
        XCTAssertEqual(Kanban.taskColumn(["column": "done"]), "done")
    }

    func testPrefersColumnOverStatusWhenBothPresent() {
        XCTAssertEqual(Kanban.taskColumn(["column": "todo", "status": "done"]), "todo")
    }

    func testFallsBackToTodoWhenMissingOrBlank() {
        XCTAssertEqual(Kanban.taskColumn(["title": "x"]), "todo")
        XCTAssertEqual(Kanban.taskColumn(["status": "   "]), "todo")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(Kanban.taskColumn(["status": "  blocked "]), "blocked")
    }

    // MARK: groupTasksByColumn

    func testBucketsTasksByColumnInTheGivenColumnOrder() {
        let tasks: [Any] = [
            ["id": "1", "status": "todo"] as JSONObject,
            ["id": "2", "status": "done"] as JSONObject,
            ["id": "3", "status": "todo"] as JSONObject,
        ]
        let grouped = Kanban.groupTasksByColumn(tasks, Kanban.columns)
        XCTAssertEqual(grouped["todo"]?.map(\.id), ["1", "3"])
        XCTAssertEqual(grouped["done"]?.map(\.id), ["2"])
    }

    func testEveryRequestedColumnGetsAPossiblyEmptyBucket() {
        let grouped = Kanban.groupTasksByColumn([], Kanban.columns)
        for column in Kanban.columns {
            XCTAssertNotNil(grouped[column], column)
            XCTAssertTrue(grouped[column]?.isEmpty ?? false, column)
        }
    }

    func testDropsTasksWhoseColumnIsNotInTheRequestedSet() {
        let tasks: [Any] = [
            ["id": "1", "status": "review"] as JSONObject,   // not in Kanban.columns
            ["id": "2", "status": "todo"] as JSONObject,
        ]
        let grouped = Kanban.groupTasksByColumn(tasks, Kanban.columns)
        let all = Kanban.columns.flatMap { grouped[$0] ?? [] }
        XCTAssertEqual(all.map(\.id), ["2"])
    }

    func testIgnoresNonMapEntriesDefensively() {
        let tasks: [Any] = ["garbage", 42, ["id": "1", "status": "ready"] as JSONObject]
        let grouped = Kanban.groupTasksByColumn(tasks, Kanban.columns)
        XCTAssertEqual(grouped["ready"]?.map(\.id), ["1"])
    }

    /// The Dart case asserted the bucket held real `Map<String, dynamic>`s; the
    /// Swift equivalent is that it holds decoded `KanbanTask` values.
    func testBucketsHoldDecodedTasks() {
        let grouped = Kanban.groupTasksByColumn(
            [["id": "1", "status": "todo", "title": "T"] as JSONObject], Kanban.columns)
        let task = grouped["todo"]?.first
        XCTAssertEqual(task?.id, "1")
        XCTAssertEqual(task?.title, "T")
        XCTAssertEqual(task?.status, "todo")
    }

    // MARK: kanbanFlattenTasks

    func testFlattensTheBridgeColumnsShape() {
        let board: JSONObject = ["columns": [
            ["name": "todo", "tasks": [["id": "1"], ["id": "2"]]],
            ["name": "done", "tasks": [["id": "3"]]],
        ]]
        let out = Kanban.flattenTasks(board)
        XCTAssertEqual(out.map { MoreJSON.text($0["id"]) }, ["1", "2", "3"])
    }

    func testToleratesABareTasksShape() {
        let out = Kanban.flattenTasks(["tasks": [["id": "a"], ["id": "b"]]])
        XCTAssertEqual(out.map { MoreJSON.text($0["id"]) }, ["a", "b"])
    }

    func testReturnsEmptyForAnEmptyOrGarbageBoard() {
        XCTAssertTrue(Kanban.flattenTasks([:]).isEmpty)
        XCTAssertTrue(Kanban.flattenTasks(["columns": "nope"]).isEmpty)
    }

    // MARK: kanbanSlugify

    func testLowercasesAndHyphenates() {
        XCTAssertEqual(Kanban.slugify("My Cool Board"), "my-cool-board")
    }

    func testStripsLeadingTrailingSeparatorsAndCollapsesRuns() {
        XCTAssertEqual(Kanban.slugify("  Hello!!  World  "), "hello-world")
    }

    func testFallsBackToBoardForEmptyInput() {
        XCTAssertEqual(Kanban.slugify("   "), "board")
        XCTAssertEqual(Kanban.slugify("!!!"), "board")
    }

    // MARK: Column presentation + dispatcher message

    func testManualColumnsExcludeRunning() {
        XCTAssertEqual(Kanban.manualColumns, ["triage", "todo", "ready", "blocked", "done"])
    }

    func testColumnLabelCapitalises() {
        XCTAssertEqual(Kanban.columnLabel("triage"), "Triage")
        XCTAssertEqual(Kanban.columnLabel(""), "")
    }

    func testColumnTones() {
        XCTAssertEqual(Kanban.columnTone("done"), .success)
        XCTAssertEqual(Kanban.columnTone("blocked"), .danger)
        XCTAssertEqual(Kanban.columnTone("running"), .cyan)
        XCTAssertEqual(Kanban.columnTone("ready"), .accent)
        XCTAssertEqual(Kanban.columnTone("triage"), .accentAlt)
        XCTAssertEqual(Kanban.columnTone("todo"), .muted)
    }

    func testDispatchMessageReadsSpawnedClaimedOrCount() {
        XCTAssertEqual(Kanban.dispatchMessage(["spawned": 2]),
                       "Dispatcher ran — 2 workers started")
        XCTAssertEqual(Kanban.dispatchMessage(["spawned": 1]),
                       "Dispatcher ran — 1 worker started")
        XCTAssertEqual(Kanban.dispatchMessage(["claimed": 0]),
                       "Dispatcher ran — no ready tasks to start")
        XCTAssertEqual(Kanban.dispatchMessage(["count": ["a", "b", "c"]]),
                       "Dispatcher ran — 3 workers started")
        XCTAssertEqual(Kanban.dispatchMessage([:]), "Dispatcher ran")
    }

    func testTaskMetaLineDropsZeroPriorityAndBlankFields() {
        let task = KanbanTask(json: ["id": "1", "assignee": " alice ",
                                     "priority": 2, "due": "Friday"])
        XCTAssertEqual(task.metaLine, "alice · P2 · due Friday")

        let bare = KanbanTask(json: ["id": "2", "priority": 0])
        XCTAssertEqual(bare.metaLine, "")
    }

    // MARK: API requests

    func testBoardsAndBoardPaths() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["boards": [["slug": "main", "name": "Main",
                                             "is_current": true, "total": 4]]])
        let boards = try await KanbanAPI(api: api).boards()
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/kanban/boards")
        XCTAssertEqual(boards.count, 1)
        XCTAssertTrue(boards[0].isCurrent)
        XCTAssertEqual(boards[0].totalLabel, "4 task(s)")

        transport.enqueue(json: ["columns": []])
        _ = try await KanbanAPI(api: api).board(slug: "side")
        XCTAssertEqual(transport.lastPath, "/api/kanban/board")
        XCTAssertEqual(transport.lastQuery, ["board": "side"])

        transport.enqueue(json: ["columns": []])
        _ = try await KanbanAPI(api: api).board()
        XCTAssertEqual(transport.lastQuery, [:], "no slug ⇒ the server's current board")
    }

    func testBoardToleratesTheNestedShape() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["board": ["columns": [["name": "todo", "tasks": [["id": "1"]]]]]])
        let board = try await KanbanAPI(api: api).board()
        XCTAssertEqual(Kanban.flattenTasks(board).count, 1)
    }

    func testStatsAndAssignees() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["by_status": ["todo": 2]])
        _ = try await KanbanAPI(api: api).stats(slug: "main")
        XCTAssertEqual(transport.lastPath, "/api/kanban/stats")
        XCTAssertEqual(transport.lastQuery, ["board": "main"])

        transport.enqueue(json: ["assignees": ["alice", "", "bob"]])
        let assignees = try await KanbanAPI(api: api).assignees()
        XCTAssertEqual(transport.lastPath, "/api/kanban/assignees")
        XCTAssertEqual(assignees, ["alice", "bob"])
    }

    func testCreateBoardSlugifiesTheTitleAndSwitches() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).createBoard(title: "My Cool Board", description: "d")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/kanban/boards")
        assertJSONEqual(transport.lastBody(), [
            "slug": "my-cool-board", "name": "My Cool Board",
            "description": "d", "switch": true,
        ])
    }

    func testSwitchRenameAndArchiveBoard() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).switchBoard("side")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/kanban/boards/side/switch")
        XCTAssertTrue(transport.lastBody().isEmpty)

        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).renameBoard("side", body: ["name": "Side quests"])
        XCTAssertEqual(transport.lastMethod, "PATCH")
        XCTAssertEqual(transport.lastPath, "/api/kanban/boards/side")
        assertJSONEqual(transport.lastBody(), ["name": "Side quests"])

        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).archiveBoard("side")
        XCTAssertEqual(transport.lastMethod, "DELETE")
        XCTAssertEqual(transport.lastPath, "/api/kanban/boards/side")
        XCTAssertEqual(transport.lastQuery, ["archive": "true"])
    }

    func testCreateTaskCarriesTheBoardAsAQueryParameter() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["task": ["id": "t1"]])
        _ = try await KanbanAPI(api: api).createTask(["title": "A", "status": "todo"], board: "main")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks")
        XCTAssertEqual(transport.lastQuery, ["board": "main"])
        assertJSONEqual(transport.lastBody(), ["title": "A", "status": "todo"])
    }

    func testPatchTaskNormalisesColumnToStatus() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["task": [:]])
        _ = try await KanbanAPI(api: api).patchTask("t1", ["column": "done"])

        XCTAssertEqual(transport.lastMethod, "PATCH")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1")
        assertJSONEqual(transport.lastBody(), ["status": "done"])
    }

    func testPatchTaskDropsColumnWhenStatusIsAlreadyPresent() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["task": [:]])
        _ = try await KanbanAPI(api: api).patchTask("t1", ["column": "todo", "status": "ready"])
        assertJSONEqual(transport.lastBody(), ["status": "ready"])
    }

    func testDeleteTaskArchivesBecauseTheBridgeHasNoDeleteRoute() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["task": [:]])
        _ = try await KanbanAPI(api: api).deleteTask("t1", board: "main")

        XCTAssertEqual(transport.lastMethod, "PATCH")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1")
        XCTAssertEqual(transport.lastQuery, ["board": "main"])
        assertJSONEqual(transport.lastBody(), ["status": "archived"])
    }

    func testCommentSendsBothBodyAndText() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).comment("t1", text: "looks good")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1/comments")
        assertJSONEqual(transport.lastBody(), ["body": "looks good", "text": "looks good"])
    }

    func testBlockAndUnblock() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).block("t1", reason: "waiting on API")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1/block")
        assertJSONEqual(transport.lastBody(), ["reason": "waiting on API"])

        transport.enqueue(json: ["ok": true])
        _ = try await KanbanAPI(api: api).unblock("t1")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1/unblock")
        XCTAssertTrue(transport.lastBody().isEmpty)
    }

    func testTaskLogPrefersLogThenContent() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["content": "from content"])
        var log = try await KanbanAPI(api: api).taskLog("t1", board: "main")
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1/log")
        XCTAssertEqual(transport.lastQuery, ["board": "main"])
        XCTAssertEqual(log, "from content")

        transport.enqueue(json: ["log": "from log", "content": "ignored"])
        log = try await KanbanAPI(api: api).taskLog("t1")
        XCTAssertEqual(log, "from log")

        transport.enqueue(json: ["other": 1])
        log = try await KanbanAPI(api: api).taskLog("t1")
        XCTAssertEqual(log, "")
    }

    func testTaskDetailParsesCommentsLinksEventsAndRuns() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "task": ["id": "t1", "status": "running", "title": "Ship"],
            "comments": [["id": "c1", "body": "hi", "author": "alice"]],
            "links": ["parents": ["p1"]],
            "events": [["kind": "claimed"]],
            "runs": [["id": "r1"]],
        ])
        let detail = try await KanbanAPI(api: api).taskDetail("t1")

        XCTAssertEqual(transport.lastPath, "/api/kanban/tasks/t1")
        XCTAssertEqual(detail.task?.status, "running")
        XCTAssertEqual(detail.comments.map(\.body), ["hi"])
        XCTAssertEqual(detail.events.count, 1)
        XCTAssertEqual(detail.runs.count, 1)
        XCTAssertNotNil(detail.links["parents"])
    }

    func testDispatchSendsDryRunMaxAndBoardAsQuery() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["spawned": 1])
        _ = try await KanbanAPI(api: api).dispatch(slug: "main", dryRun: true, max: 3)

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/kanban/dispatch")
        XCTAssertEqual(transport.lastQuery, ["dry_run": "true", "max": "3", "board": "main"])
        XCTAssertTrue(transport.lastBody().isEmpty)

        transport.enqueue(json: ["spawned": 0])
        _ = try await KanbanAPI(api: api).dispatch()
        XCTAssertEqual(transport.lastQuery, ["dry_run": "false", "max": "8"])
    }

    func testEventsStreamsSSE() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueueSSE("""
        event: task.updated
        data: {"task_id":"t1"}

        event: task.created
        data: {"task_id":"t2"}

        """)
        let events = try await collect(KanbanAPI(api: api).events())

        XCTAssertEqual(transport.lastPath, "/api/kanban/events/stream")
        XCTAssertEqual(events.map(\.event), ["task.updated", "task.created"])
        XCTAssertEqual(events[0].string("task_id"), "t1")
    }

    // MARK: Store

    @MainActor
    private func makeStore(_ transport: MockTransport, api: JarvisAPI) -> KanbanStore {
        KanbanStore(api: KanbanAPI(api: api), pollInterval: 0.01, sleeper: instantSleeper)
    }

    @MainActor
    func testStoreGroupsSectionsAndHidesEmptyColumns() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/boards",
                        json: ["boards": [["slug": "main", "is_current": true]]])
        transport.route("/api/kanban/board", json: ["columns": [
            ["name": "todo", "tasks": [["id": "1", "status": "todo"]]],
            ["name": "done", "tasks": [["id": "2", "status": "done"]]],
        ]])

        let store = makeStore(transport, api: api)
        await store.refresh()

        XCTAssertEqual(store.currentSlug, "main")
        XCTAssertEqual(store.sections.map(\.column), ["todo", "done"])
        XCTAssertEqual(store.count(in: "ready"), 0)
        XCTAssertFalse(store.isEmpty)
    }

    @MainActor
    func testStoreColumnFilterNarrowsTheSections() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board", json: ["columns": [
            ["name": "todo", "tasks": [["id": "1", "status": "todo"]]],
            ["name": "done", "tasks": [["id": "2", "status": "done"]]],
        ]])

        let store = makeStore(transport, api: api)
        await store.refresh()

        store.columnFilter = "done"
        XCTAssertEqual(store.sections.map(\.column), ["done"])
        store.columnFilter = "ready"
        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertTrue(store.filteredToEmptyColumn)
    }

    @MainActor
    func testStoreKeepsTheBoardWhenTheSwitcherFetchFails() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/boards", json: ["error": "nope"], status: 500)
        transport.route("/api/kanban/board",
                        json: ["columns": [["name": "todo", "tasks": [["id": "1", "status": "todo"]]]]])

        let store = makeStore(transport, api: api)
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.allTasks.map(\.id), ["1"])
        XCTAssertTrue(store.boards.isEmpty)
    }

    @MainActor
    func testStoreCreateTaskRequiresATitle() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = makeStore(transport, api: api)
        let ok = await store.createTask(title: "   ", body: "", column: "todo",
                                        assignee: "", priority: 0)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.toast, "Title is required")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreCreateTaskOmitsABlankAssignee() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/tasks", json: ["task": ["id": "t1"]])
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board", json: ["columns": []])

        let store = makeStore(transport, api: api)
        let ok = await store.createTask(title: " Ship it ", body: " notes ",
                                        column: "ready", assignee: "  ", priority: 3)
        XCTAssertTrue(ok)
        assertJSONEqual(transport.body(0), [
            "title": "Ship it", "body": "notes", "status": "ready", "priority": 3,
        ])
    }

    @MainActor
    func testStoreRunRefusesAnUnassignedTask() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = makeStore(transport, api: api)
        await store.run(KanbanTask(json: ["id": "t1", "status": "ready"]))
        XCTAssertEqual(store.toast,
                       "Assign a profile to this task first (Edit → Assignee), then Run.")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreRunDispatchesForAnAssignedTask() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/dispatch", json: ["spawned": 1])
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board", json: ["columns": []])

        let store = makeStore(transport, api: api)
        await store.run(KanbanTask(json: ["id": "t1", "status": "ready", "assignee": "alice"]))
        XCTAssertEqual(store.toast, "Dispatcher ran — 1 worker started")
    }

    @MainActor
    func testStoreSwitchBoardClearsTheLocalOverride() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/boards/side/switch", json: ["ok": true])
        transport.route("/api/kanban/boards",
                        json: ["boards": [["slug": "side", "is_current": true]]])
        transport.route("/api/kanban/board", json: ["columns": []])

        let store = makeStore(transport, api: api)
        await store.switchBoard("side")

        XCTAssertNil(store.boardSlug)
        XCTAssertEqual(store.currentSlug, "side")
        XCTAssertEqual(transport.path(0), "/api/kanban/boards/side/switch")
    }

    @MainActor
    func testStoreFallsBackToPollingWhenTheEventStreamEnds() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/events/stream", json: [:])   // ends immediately
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board", json: ["columns": []])

        let store = makeStore(transport, api: api)
        store.onAppear()
        // Let the (immediately-finishing) stream task run and arm the poll.
        for _ in 0..<20 where !store.isPolling { await Task.yield() }
        XCTAssertTrue(store.isPolling)
        store.onDisappear()
    }

    @MainActor
    func testDetailStoreStopMovesTheTaskToTodo() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/tasks/t1", json: ["task": ["id": "t1", "status": "todo"]])

        let detail = KanbanTaskDetailStore(
            api: KanbanAPI(api: api),
            task: KanbanTask(json: ["id": "t1", "status": "running"]),
            board: "main", pollInterval: 0.01, sleeper: instantSleeper)
        await detail.stop()

        XCTAssertEqual(transport.method(0), "PATCH")
        XCTAssertEqual(transport.path(0), "/api/kanban/tasks/t1")
        XCTAssertEqual(transport.query(0), ["board": "main"])
        assertJSONEqual(transport.body(0), ["status": "todo"])
        XCTAssertEqual(detail.toast, "Task stopped (moved to Todo)")
        detail.onDisappear()
    }

    @MainActor
    func testDetailStorePostCommentRefusesBlankText() async {
        let (api, transport) = JarvisAPI.mocked()
        let detail = KanbanTaskDetailStore(
            api: KanbanAPI(api: api),
            task: KanbanTask(json: ["id": "t1", "status": "todo"]),
            board: nil, pollInterval: 0.01, sleeper: instantSleeper)
        let ok = await detail.postComment("   ")
        XCTAssertFalse(ok)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

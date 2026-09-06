import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Hosting smoke tests for the first half of the More pages: build each screen's
/// store on a mocked transport, drive it into a loaded (or failed) state, then
/// render the real SwiftUI view through `UIHostingController`.
///
/// This is what catches the mistakes unit tests on the stores cannot — a crash
/// in a `ForEach` id, a `Binding` into a `let`, a layout that traps on an empty
/// collection — without needing a UI test target.
@MainActor
final class MoreUIAHostingTests: XCTestCase {

    // MARK: Todos

    func testTodosPageRendersALoadedList() async {
        let (api, t) = JarvisAPI.mocked()
        // "/api/sessions" must be registered before "/api/session": the router
        // matches on a path substring, first rule wins.
        t.route("/api/sessions", json: ["sessions": [["session_id": "s1", "updated_at": 100]]])
        t.route("/api/session", json: ["session": ["messages": [
            moreUIAToolMessage([
                ["id": "1", "content": "Write the code", "status": "in_progress"],
                ["id": "2", "content": "Ship it", "status": "pending"],
                ["id": "3", "content": "Old thing", "status": "completed"],
            ]),
        ]]])
        let store = TodosStore(api: TodosAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.todos.count, 3)
        XCTAssertEqual(store.progressLabel, "1 / 3 done")
        moreUIAHost(TodosPage(store: store))
    }

    func testTodosPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = TodosStore(api: TodosAPI(api: api))
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.todos.isEmpty)
        moreUIAHost(TodosPage(store: store))
    }

    // MARK: Memory

    func testMemoryPageRendersALoadedDocument() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/memory", json: [
            "memory": "# Notes\n- ship the port",
            "user": "Pranav, iOS.",
            "memory_path": "/srv/MEMORY.md",
            "memory_mtime": 1_718_900_000,
        ])
        let store = MemoryStore(api: MemoryAPI(api: api))
        await store.refresh()

        XCTAssertTrue(store.canEdit)
        XCTAssertFalse(store.mtimeLabel.isEmpty)
        moreUIAHost(MemoryPage(store: store))
    }

    func testMemoryPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = MemoryStore(api: MemoryAPI(api: api))
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.canEdit)
        moreUIAHost(MemoryPage(store: store))
    }

    func testMemoryEditorRendersWithADraft() {
        let editor = MemoryEditorView(title: "My Notes", initialContent: "# Notes") { _ in true }
        XCTAssertNil(editor.visibleSaveError, "nothing has failed yet")
        XCTAssertFalse(editor.isSaving)
        moreUIAHost(editor)
    }

    /// A save that fails leaves the sheet open, which on its own is
    /// indistinguishable from a tap that missed the button — the error has to be
    /// visible INSIDE the editor (silent-failures H7).
    func testMemoryEditorShowsWhyASaveFailed() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["memory": "old", "memory_path": "/x/MEMORY.md"])
        transport.enqueue(json: ["error": "disk full"], status: 500)
        let store = MemoryStore(api: MemoryAPI(api: api))
        await store.refresh()

        let saved = await store.save("new")

        XCTAssertFalse(saved, "the editor stays open")
        XCTAssertNotNil(store.errorMessage)
        moreUIAHost(MemoryEditorView(title: "My Notes", initialContent: "old",
                                     saveError: store.errorMessage) { _ in false })
    }

    /// The message only appears once THIS editor's save came back false — a
    /// stale store error from an earlier load must not accuse the user.
    func testTheEditorDoesNotShowAStaleStoreError() {
        let editor = MemoryEditorView(title: "My Notes", initialContent: "x",
                                      saveError: "an old load failure") { _ in true }
        XCTAssertNil(editor.visibleSaveError)
        moreUIAHost(editor)
    }

    // MARK: Long-term memory

    func testLongTermMemoryPageRendersStatsResultsAndReflections() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/jarvis-memory/stats", json: [
            "available": true, "count": 12,
            "namespaces": [["namespace": "chat", "count": 9],
                           ["namespace": "notes", "count": 3]],
        ])
        t.route("/api/jarvis-memory/status", json: ["available": true, "embed_model": "nomic"])
        t.route("/api/jarvis-memory/search", json: ["entries": [
            ["id": "e1", "body": "Prefers dark mode", "source": "chat",
             "namespace": "chat", "score": 0.87, "created_at": 1_718_900_000],
        ]])
        t.route("/api/jarvis-memory/reflections", json: ["reflections": [
            ["id": 3, "kind": "habit", "title": "You work late", "body": "Most turns after 10pm"],
        ]])
        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api),
                                      searchDebounce: 0, sleeper: instantSleeper)
        await store.refresh()

        XCTAssertTrue(store.available)
        XCTAssertEqual(store.data.count, 12)
        XCTAssertEqual(store.namespaces.count, 2)
        XCTAssertEqual(store.results.count, 1)
        XCTAssertEqual(store.reflections.count, 1)
        moreUIAHost(LongTermMemoryPage(store: store))
    }

    /// The store fail-softs to `{available:false}` — the page must show the
    /// unavailable card rather than an empty list.
    func testLongTermMemoryPageRendersTheUnavailableState() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/jarvis-memory/stats",
                json: ["available": false, "error": "jarvis_memory not initialised"])
        t.route("/api/jarvis-memory/status", json: ["available": false])
        t.route("/api/jarvis-memory/search", json: ["entries": []])
        t.route("/api/jarvis-memory/reflections", json: ["reflections": []])
        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api),
                                      searchDebounce: 0, sleeper: instantSleeper)
        await store.refresh()

        XCTAssertFalse(store.available)
        XCTAssertEqual(store.unavailableMessage, "jarvis_memory not initialised")
        moreUIAHost(LongTermMemoryPage(store: store))
    }

    /// A failed header request leaves `available` true (it only goes false on an
    /// explicit `available: false` body), so the page has to key its error state
    /// off `errorMessage` rather than availability.
    func testLongTermMemoryPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api),
                                      searchDebounce: 0, sleeper: instantSleeper)
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.available)
        moreUIAHost(LongTermMemoryPage(store: store))
    }

    // MARK: Code memory

    func testCodeMemoryPageRendersTotalsAndProjects() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/code-memory/stats", json: [
            "projects": 2, "knowledge": 10, "sessions": 4,
            "last_activity": "2026-09-04T09:00:00Z",
        ])
        t.route("/api/code-memory/projects", json: ["projects": [
            "repo-a": ["name": "Repo A", "knowledge_count": 7, "sessions_count": 3,
                       "last_seen": "2026-09-04T09:00:00Z"],
            "repo-b": ["name": "Repo B", "knowledge_count": 3, "sessions_count": 1],
        ]])
        let store = CodeMemoryStore(api: CodeMemoryAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.overview.totalProjects, 2)
        XCTAssertEqual(store.overview.totalKnowledge, 10)
        XCTAssertEqual(store.visibleProjects.count, 2)
        moreUIAHost(CodeMemoryPage(store: store))
    }

    func testCodeMemoryPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = CodeMemoryStore(api: CodeMemoryAPI(api: api))
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        moreUIAHost(CodeMemoryPage(store: store))
    }

    func testCodeMemoryEntriesViewRendersALoadedList() async {
        let (api, t) = JarvisAPI.mocked()
        // The bare "/api/code-memory" rule matches every sibling path, so it has
        // to be registered last.
        t.route("/api/code-memory", json: ["entries": [
            ["id": "repo-a::knowledge::1::0", "ts": "2026-09-04T09:00:00Z",
             "entry_type": "note", "content": "Build with scripts/build.sh\nmore"],
        ]])
        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api),
                                           slug: "repo-a", kind: .knowledge)
        await store.refresh()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].title(kind: .knowledge), "Build with scripts/build.sh")
        moreUIAHost(CodeMemoryEntriesView(store: store, onChanged: {}))
    }

    func testCodeMemoryEntriesViewRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api),
                                           slug: "repo-a", kind: .sessions)
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        moreUIAHost(CodeMemoryEntriesView(store: store, onChanged: {}))
    }

    // MARK: Kanban

    func testKanbanPageRendersGroupedColumns() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/kanban/boards", json: ["boards": [
            ["slug": "main", "name": "Main", "is_current": true, "total": 3],
            ["slug": "ops", "name": "Ops"],
        ]])
        t.route("/api/kanban/board", json: ["columns": [
            ["name": "todo", "tasks": [
                ["id": "t1", "title": "Do the thing", "status": "todo",
                 "assignee": "alice", "priority": 2],
            ]],
            ["name": "running", "tasks": [
                ["id": "t2", "title": "Streaming", "status": "running"],
            ]],
            ["name": "blocked", "tasks": [
                ["id": "t3", "title": "Waiting on API", "status": "blocked"],
            ]],
        ]])
        // A real (long) poll interval: the SSE subscription this page starts on
        // appear fails against the mock, and an instant sleeper would then spin.
        let store = KanbanStore(api: KanbanAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.allTasks.count, 3)
        XCTAssertEqual(store.sections.map(\.column), ["todo", "running", "blocked"])
        XCTAssertEqual(store.activeBoard?.displayName, "Main")
        moreUIAHost(KanbanPage(store: store))
    }

    func testKanbanPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = KanbanStore(api: KanbanAPI(api: api))
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.allTasks.isEmpty)
        moreUIAHost(KanbanPage(store: store))
    }

    func testKanbanTaskDetailRendersCommentsAndLog() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/kanban/tasks/t1/log", json: ["content": "worker started\ndone"])
        t.route("/api/kanban/tasks/t1", json: [
            "task": ["id": "t1", "title": "Do the thing", "status": "running",
                     "assignee": "alice", "priority": 2, "body": "details here"],
            "comments": [["id": "c1", "author": "alice", "body": "on it"]],
            "links": ["parents": ["t0"], "children": []],
        ])
        let task = KanbanTask(json: ["id": "t1", "title": "Do the thing", "status": "running"])
        let store = KanbanTaskDetailStore(api: KanbanAPI(api: api), task: task, board: nil)
        await store.loadDetail()
        store.onDisappear()   // stop the 2.5 s poll the running task just armed

        XCTAssertEqual(store.comments.count, 1)
        XCTAssertTrue(store.isRunning)
        moreUIAHost(KanbanTaskDetailView(store: store, onRun: {}, onAction: { _ in }))
    }

    func testKanbanTaskFormRenders() {
        let task = KanbanTask(json: ["id": "t1", "title": "Edit me", "status": "todo",
                                     "priority": 3, "assignee": "bob"])
        // The sheet seeds its fields from the task, so a parse that dropped them
        // would host a blank form and still "pass".
        XCTAssertEqual(task.title, "Edit me")
        XCTAssertEqual(task.status, "todo")
        XCTAssertEqual(task.priority, "3")
        XCTAssertEqual(task.assignee, "bob")
        moreUIAHost(KanbanTaskFormSheet(title: "Edit task", showsColumn: false,
                                        task: task) { _, _, _, _, _ in true })
    }

    // MARK: Tasks (cron)

    func testTasksPageRendersJobCards() async {
        let (api, t) = JarvisAPI.mocked()
        t.route("/api/crons", json: ["jobs": [
            ["id": "j1", "name": "Daily digest", "prompt": "Summarise my day",
             "schedule_display": "every day at 9am", "state": "scheduled",
             "next_run": "2026-09-05T09:00:00Z", "last_run": "2026-09-04T09:00:00Z",
             "deliver": "telegram", "skills": ["email", "calendar"]],
            ["id": "j2", "name": "Paused one", "state": "paused", "deliver": "local"],
        ]])
        let store = CronsStore(api: CronsAPI(api: api))
        await store.refresh()
        store.onDisappear()

        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertEqual(store.jobs[0].statusLabel, "ACTIVE")
        XCTAssertTrue(store.jobs[1].isPaused)
        XCTAssertEqual(store.skillOptions(), ["calendar", "email"])
        moreUIAHost(TasksPage(store: store))
    }

    func testTasksPageRendersTheErrorState() async {
        let (api, _) = JarvisAPI.mocked()
        let store = CronsStore(api: CronsAPI(api: api))
        await store.refresh()
        store.onDisappear()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.jobs.isEmpty)
        moreUIAHost(TasksPage(store: store))
    }

    func testCronDetailRendersHistoryAndFields() async {
        let (api, t) = JarvisAPI.mocked()
        // "/api/crons/history" must precede "/api/crons", which matches it too.
        t.route("/api/crons/history", json: ["runs": [
            ["filename": "2026-09-04_0900.md", "size": 2048, "status": "ok"],
        ]])
        t.route("/api/crons", json: ["jobs": []])
        let job = CronJob(json: ["id": "j1", "name": "Daily digest",
                                 "prompt": "Summarise my day",
                                 "schedule_display": "every day at 9am",
                                 "deliver": "telegram", "skills": ["email"],
                                 "state": "scheduled"])
        let history = CronHistoryStore(api: CronsAPI(api: api), jobID: "j1")
        await history.load()

        XCTAssertEqual(history.runs.count, 1)
        XCTAssertEqual(history.runs[0].label, "2026-09-04 0900")
        moreUIAHost(CronDetailView(job: job, history: history, onAction: { _ in }))
    }

    func testCronFormSheetRendersForAnExistingJob() {
        let job = CronJob(json: ["id": "j1", "name": "Daily digest", "prompt": "Summarise",
                                 "schedule_display": "every day at 9am",
                                 "deliver": "carrier-pigeon", "skills": ["email"]])
        XCTAssertEqual(job.name, "Daily digest")
        XCTAssertEqual(job.prompt, "Summarise")
        XCTAssertEqual(job.skills, ["email"])
        // An unknown delivery channel has to survive the round trip — the sheet
        // renders it as a choice rather than silently resetting it.
        XCTAssertEqual(job.deliver, "carrier-pigeon")
        moreUIAHost(CronFormSheet(existing: job, allSkills: ["email", "calendar"]) { _ in true })
    }
}

// MARK: - Helpers

/// Render a view for real: a hosting controller inside a phone-sized window,
/// laid out once. The window matters — a detached `UIHostingController` never
/// builds its SwiftUI tree, so `layoutIfNeeded` alone proves nothing.
///
/// Prefixed with the area name: a bare `host` would reserve that symbol
/// module-wide for every other agent's tests.
@MainActor
func moreUIAHost(_ view: some View, file: StaticString = #filePath, line: UInt = #line) {
    let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
    let controller = UIHostingController(rootView: NavigationStack { view })
    let window = UIWindow(frame: frame)
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = frame
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    // A tree that trapped or collapsed lays out to nothing; a rendered one has
    // a real size and at least one hosted subview.
    XCTAssertGreaterThan(controller.view.bounds.width, 0, file: file, line: line)
    XCTAssertFalse(controller.view.subviews.isEmpty, file: file, line: line)
    window.isHidden = true
    window.rootViewController = nil
}

/// A `role: "tool"` message whose JSON `content` carries a todo list — the only
/// shape `TodosParser` accepts.
func moreUIAToolMessage(_ todos: [JSONObject]) -> JSONObject {
    let data = try! JSONSerialization.data(withJSONObject: ["todos": todos])
    return ["role": "tool", "content": String(decoding: data, as: UTF8.self)]
}

import XCTest
@testable import JarvisCopilot

/// The pure view-level helpers the first half of the More pages introduced:
/// the presentation routes (SwiftUI keys sheets off `Identifiable`, so a
/// colliding id silently reuses the wrong sheet) and the confirmation copy.
final class MoreUIARouteTests: XCTestCase {

    private func task(_ id: String, title: String = "", status: String = "todo") -> KanbanTask {
        KanbanTask(json: ["id": id, "title": title, "status": status])
    }

    // MARK: KanbanRoute

    func testKanbanRouteIDsAreUniquePerKindAndTask() {
        let a = task("t1")
        let b = task("t2")
        let routes: [KanbanRoute] = [
            .createTask, .editTask(a), .taskDetail(a), .move(a), .block(a), .comment(a),
            .boardPicker, .boardActions, .createBoard,
            .renameBoard(KanbanBoard(slug: "ops")),
            .editTask(b),
        ]
        XCTAssertEqual(Set(routes.map(\.id)).count, routes.count)
    }

    func testKanbanRouteIDCarriesTheTaskSoASecondTaskOpensAFreshSheet() {
        XCTAssertEqual(KanbanRoute.taskDetail(task("t9")).id, "taskDetail:t9")
        XCTAssertNotEqual(KanbanRoute.editTask(task("t9")).id,
                          KanbanRoute.taskDetail(task("t9")).id)
    }

    // MARK: KanbanConfirm

    func testDeleteTaskConfirmNamesTheTask() {
        let confirm = KanbanConfirm.deleteTask(task("t1", title: "Ship it"))
        XCTAssertEqual(confirm.title, "Delete task?")
        XCTAssertEqual(confirm.actionLabel, "Delete")
        XCTAssertTrue(confirm.message.contains("Ship it"), confirm.message)
    }

    /// An untitled task still has to name *something* the user can recognise.
    func testDeleteTaskConfirmFallsBackToTheID() {
        let confirm = KanbanConfirm.deleteTask(task("t_42"))
        XCTAssertTrue(confirm.message.contains("t_42"), confirm.message)
    }

    func testArchiveBoardConfirmUsesTheBoardDisplayName() {
        let confirm = KanbanConfirm.archiveBoard(KanbanBoard(slug: "ops", name: "Operations"))
        XCTAssertEqual(confirm.title, "Archive board?")
        XCTAssertEqual(confirm.actionLabel, "Archive")
        XCTAssertTrue(confirm.message.contains("Operations"), confirm.message)
    }

    func testConfirmIDsAreDistinct() {
        let a = KanbanConfirm.deleteTask(task("t1"))
        let b = KanbanConfirm.archiveBoard(KanbanBoard(slug: "t1"))
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: TasksRoute

    func testTasksRouteIDsAreUnique() {
        let job = CronJob(json: ["id": "j1", "name": "Digest"])
        let other = CronJob(json: ["id": "j2"])
        let routes: [TasksRoute] = [.create, .edit(job), .detail(job), .edit(other)]
        XCTAssertEqual(Set(routes.map(\.id)).count, routes.count)
        XCTAssertEqual(TasksRoute.detail(job).id, "detail:j1")
    }

    // MARK: CronFormValues

    /// A brand-new job defaults to in-app delivery with completion toasts on —
    /// the same defaults the Flutter form used.
    func testCronFormValuesDefaults() {
        let form = CronFormValues()
        XCTAssertEqual(form.deliver, "local")
        XCTAssertTrue(form.toastNotifications)
        XCTAssertTrue(form.skills.isEmpty)
        XCTAssertEqual(form.prompt, "")
    }
}

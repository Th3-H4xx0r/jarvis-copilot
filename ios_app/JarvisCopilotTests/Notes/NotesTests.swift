import Foundation
import XCTest
@testable import JarvisCopilot

/// More → Notes: the call notes the Mac's note-taker uploads to
/// `/api/agent-notes` (webui/api/agent_notes_routes.py). The model, the REST
/// client and the push-driven store.
@MainActor
final class NotesTests: XCTestCase {

    private static let id = "6F1C1D2E-0A4B-4C1D-9E2F-1234567890AB"

    private static func full(_ over: [String: Any] = [:]) -> [String: Any] {
        var note: [String: Any] = [
            "id": id, "title": "Beta launch plan", "title_edited": false,
            "start": 1_760_450_400.0, "end": 1_760_452_320.0, "app": "Zoom",
            "speakers": [["id": "me", "name": "You", "is_me": true], ["id": "them", "name": "Them", "is_me": false]],
            "lines": [["speaker": "me", "start": 0.0, "end": 3.5, "text": "Let's ship Friday."],
                      ["speaker": "them", "start": 75.0, "end": 80.0, "text": "Notes by Thursday."]],
            "summary": "The beta ships Friday.", "key_points": ["Beta Friday", ""],
            "todos": [["text": "Write the release notes", "owner": "Them", "due": "Thursday", "done": false],
                      ["text": "Book the room", "owner": NSNull(), "due": NSNull(), "done": true]],
            "summary_status": "done", "summary_error": NSNull(), "updated_at": 1_760_452_400.0,
        ]
        for (k, v) in over { note[k] = v }
        return note
    }

    private func makeAPI() -> (NotesAPI, MockTransport) {
        let transport = MockTransport()
        return (NotesAPI(api: JarvisAPI(credentials: TestCredentials(), transport: transport)), transport)
    }

    // MARK: model

    func testAFullNoteParses() throws {
        let note = try XCTUnwrap(AgentNote(json: Self.full()))
        XCTAssertEqual(note.id, Self.id)
        XCTAssertEqual(note.title, "Beta launch plan")
        XCTAssertEqual(note.start, Date(timeIntervalSince1970: 1_760_450_400))
        XCTAssertEqual(note.duration, 1920, accuracy: 0.001)
        XCTAssertEqual(note.app, "Zoom")
        XCTAssertEqual(note.speakers.map(\.name), ["You", "Them"])
        XCTAssertEqual(note.lines.count, 2)
        XCTAssertEqual(note.name(of: "them"), "Them")
        XCTAssertEqual(note.keyPoints, ["Beta Friday"])
        XCTAssertEqual(note.todos.map(\.text), ["Write the release notes", "Book the room"])
        XCTAssertNil(note.todos[1].owner)
        XCTAssertTrue(note.todos[1].done)
        XCTAssertEqual(note.summaryStatus, .done)
        XCTAssertEqual(note.lineCount, 2)
    }

    func testAListRowHasNoTranscriptButKnowsItsSize() throws {
        var row = Self.full(["line_count": 42, "duration": 600.0])
        row["lines"] = nil
        row["end"] = NSNull()
        let note = try XCTUnwrap(AgentNote(json: row))
        XCTAssertTrue(note.lines.isEmpty)
        XCTAssertEqual(note.lineCount, 42)
        XCTAssertEqual(note.duration, 600, accuracy: 0.001)
        XCTAssertEqual(note.minutes, 10)
    }

    func testANoteWithoutAnIdIsDropped() {
        XCTAssertNil(AgentNote(json: ["title": "x"]))
        XCTAssertNil(AgentNote(json: Self.full(["id": ""])))
    }

    func testUnknownSpeakersAndStatusesFallBack() throws {
        let note = try XCTUnwrap(AgentNote(json: Self.full(["speakers": [], "summary_status": "weird"])))
        XCTAssertEqual(note.name(of: "me"), "You")
        XCTAssertEqual(note.name(of: "them"), "Them")
        XCTAssertEqual(note.summaryStatus, .none)
    }

    func testTodosGoBackInTheServersShape() throws {
        let note = try XCTUnwrap(AgentNote(json: Self.full()))
        let json = note.todosJSON(toggling: 0)
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["done"] as? Bool, true)
        XCTAssertEqual(json[1]["done"] as? Bool, true)
        XCTAssertEqual(json[0]["owner"] as? String, "Them")
        XCTAssertTrue(json[1]["owner"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    // MARK: API

    func testListIsTheNotesArray() async throws {
        let (api, transport) = makeAPI()
        transport.enqueue(json: ["notes": [Self.full(), ["no": "id"]]])
        let notes = try await api.list()
        XCTAssertEqual(notes.map(\.id), [Self.id])
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/agent-notes")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
    }

    func testMarkdownAsksInTheViewersTimeZone() async throws {
        let (api, transport) = makeAPI()
        transport.enqueue(json: ["markdown": "# Beta", "filename": "Beta.md"])
        let md = try await api.markdown(Self.id, timeZone: TimeZone(secondsFromGMT: 2 * 3600)!)
        XCTAssertEqual(md.text, "# Beta")
        XCTAssertEqual(md.filename, "Beta.md")
        let url = try XCTUnwrap(transport.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/agent-notes/\(Self.id)/markdown")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "-120")
    }

    func testTodosAreSavedWithAPost() async throws {
        let (api, transport) = makeAPI()
        transport.enqueue(json: ["note": Self.full()])
        _ = try await api.setTodos(Self.id, [["text": "A", "done": true]])
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/agent-notes/\(Self.id)")
        XCTAssertEqual((transport.lastBody()["todos"] as? [[String: Any]])?.first?["text"] as? String, "A")
    }

    func testDeleteAndSummarize() async throws {
        let (api, transport) = makeAPI()
        transport.enqueue(json: ["ok": true])
        try await api.delete(Self.id)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "DELETE")
        transport.enqueue(json: ["note": Self.full(["summary_status": "pending"])])
        let note = try await api.summarize(Self.id)
        XCTAssertEqual(note.summaryStatus, .pending)
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/agent-notes/\(Self.id)/summarize")
    }

    // MARK: store

    private func makeStore() -> (NotesStore, MockTransport, BridgeTopics, [[String: Any]]) {
        let (api, transport) = makeAPI()
        let topics = BridgeTopics()
        var sent: [[String: Any]] = []
        topics.send = { sent.append($0) }
        return (NotesStore(api: api, topics: topics), transport, topics, sent)
    }

    func testRefreshFillsTheList() async {
        let (store, transport, _, _) = makeStore()
        transport.enqueue(json: ["notes": [Self.full()]])
        await store.refresh()
        XCTAssertTrue(store.loaded)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notes.first?.title, "Beta launch plan")
    }

    func testARefreshFailureIsShownNotThrown() async {
        let (store, transport, _, _) = makeStore()
        transport.enqueue(json: ["error": "boom"], status: 500)
        await store.refresh()
        XCTAssertTrue(store.loaded)
        XCTAssertNotNil(store.loadError)
    }

    func testTheScreenWantsTheNotesTopicOnlyWhileVisible() {
        let (store, _, topics, _) = makeStore()
        store.setVisible(true, owner: "notes-page")
        XCTAssertTrue(topics.isWanted("notes"))
        store.setVisible(false, owner: "notes-page")
        XCTAssertFalse(topics.isWanted("notes"))
    }

    func testAPushedDeletionDropsTheNote() async {
        let (store, transport, topics, _) = makeStore()
        transport.enqueue(json: ["notes": [Self.full()]])
        await store.refresh()
        topics.deliver(["type": "topic", "topic": "notes", "data": ["id": Self.id, "deleted": true]])
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testTogglingATodoSendsTheListAndTakesTheReply() async throws {
        let (store, transport, _, _) = makeStore()
        transport.enqueue(json: Self.full())
        await store.load(Self.id)
        var flipped = Self.full()
        flipped["todos"] = [["text": "Write the release notes", "owner": "Them", "due": "Thursday", "done": true],
                            ["text": "Book the room", "done": true]]
        transport.enqueue(json: ["note": flipped])
        await store.toggleTodo(Self.id, index: 0)
        XCTAssertEqual(store.details[Self.id]?.todos.first?.done, true)
        XCTAssertEqual((transport.lastBody()["todos"] as? [[String: Any]])?.first?["done"] as? Bool, true)
    }

    func testDeleteRemovesIt() async {
        let (store, transport, _, _) = makeStore()
        transport.enqueue(json: ["notes": [Self.full()]])
        await store.refresh()
        transport.enqueue(json: ["ok": true])
        let ok = await store.delete(Self.id)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.notes.isEmpty)
    }
}

import Foundation
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Integrations screen's model layer: what the list row says, what the
/// detail keeps, and how the plan card finds its plan in a tool result.
final class IntegrationsTests: XCTestCase {

    // MARK: The list row

    func testTheSubtitleCountsWhatThereIs() {
        let row = Integration(json: [
            "id": "casino", "name": "Casino Earnings",
            "schedule_count": 2, "enabled_schedule_count": 1,
            "record_count": 18, "skill_count": 1,
        ])
        XCTAssertEqual(row.subtitle, "2 schedules (1 off) · 18 records · 1 skill")
    }

    func testOneOfEachReadsSingular() {
        let row = Integration(json: ["id": "x", "schedule_count": 1,
                                     "enabled_schedule_count": 1, "skill_count": 1])
        XCTAssertEqual(row.subtitle, "1 schedule · 1 skill")
    }

    func testDocumentsStandInWhenThereAreNoRecords() {
        let row = Integration(json: ["id": "x", "document_count": 3])
        XCTAssertEqual(row.subtitle, "3 stored")
    }

    func testAnEmptyIntegrationSaysSo() {
        XCTAssertEqual(Integration(json: ["id": "general"]).subtitle, "nothing yet")
    }

    func testTheNameFallsBackToTheID() {
        XCTAssertEqual(Integration(json: ["id": "casino"]).name, "casino")
    }

    func testStatusDefaultsToActive() {
        XCTAssertFalse(Integration(json: ["id": "x"]).isPaused)
        XCTAssertTrue(Integration(json: ["id": "x", "status": "paused"]).isPaused)
    }

    // MARK: The detail

    func testTheMigrationsBookkeepingIsNotShownAsData() {
        let detail = IntegrationDetail(json: [
            "id": "casino",
            "documents": [["key": "summary"], ["key": "imported_files"]],
            "collections": [["name": "sessions", "count": 18]],
        ])
        XCTAssertEqual(detail.documents.map(\.key), ["summary"])
        XCTAssertFalse(detail.hasNothingStored)
    }

    func testDocumentSizesReadInTheRightUnit() {
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 900]).sizeLabel, "900 B")
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 4096]).sizeLabel, "4 KB")
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 2_621_440]).sizeLabel, "2.5 MB")
    }

    func testARecordDrawsWhateverFieldsItCarries() {
        let record = IntegrationRecord(json: ["id": 4, "ts": 1_700_000_000,
                                              "game": "blackjack", "net": -120], index: 0)
        XCTAssertEqual(record.fields.map(\.key), ["game", "net"])   // ts and id are not fields
        XCTAssertEqual(record.fields.first?.value, "blackjack")
        XCTAssertFalse(record.timeLabel.isEmpty)
    }

    // MARK: Which integration owns a schedule

    func testAnUntaggedScheduleBelongsToGeneral() {
        XCTAssertEqual(CronJob(json: ["id": "j1"]).integrationID, "general")
        XCTAssertEqual(CronJob(json: ["id": "j1", "integration": "  Casino "]).integrationID, "casino")
    }

    // MARK: The plan card

    func testThePlanIDComesOutOfTheToolResult() {
        let tool = ToolInvocation(
            name: "integration_plan_propose",
            result: #"{"ok": true, "plan": {"id": "a1b2c3d4e5f6", "space_id": "gym-sessions"}}"#)
        XCTAssertEqual(IntegrationPlanCard.planID(in: tool), "a1b2c3d4e5f6")
    }

    func testThePlanIDSurvivesATruncatedResult() {
        // The chat keeps only the head of a long result; the id is near the front.
        let tool = ToolInvocation(
            name: "integration_plan_propose",
            result: #"{"ok": true, "plan": {"id": "a1b2c3d4e5f6", "space_id": "gym-ses"#)
        XCTAssertEqual(IntegrationPlanCard.planID(in: tool), "a1b2c3d4e5f6")
    }

    func testAnotherToolIsNeverAPlanCard() {
        let tool = ToolInvocation(name: "registry_query",
                                  result: #"{"ok": true, "plan": {"id": "nope"}}"#)
        XCTAssertNil(IntegrationPlanCard.planID(in: tool))
    }

    func testAPlanStillRunningHasNoIDYet() {
        XCTAssertNil(IntegrationPlanCard.planID(in: ToolInvocation(name: "integration_plan_propose")))
    }

    func testThePlanRendersWhatTheModelProposed() {
        let plan = IntegrationPlan(json: [
            "id": "p1", "space_id": "gym-sessions", "name": "Gym Sessions",
            "summary": "Logs your workouts.", "icon": "bolt", "status": "pending",
            "schedules": [["name": "weekly", "schedule": "0 19 * * 0", "purpose": "Sunday recap",
                           "prompt": "a prompt the card never shows"]],
            "collections": [["name": "sessions", "description": "one workout"]],
            "skills": [["name": "gym-logger", "purpose": "Log from a sentence."]],
        ])
        XCTAssertTrue(plan.isPending)
        XCTAssertEqual(plan.statusLabel, "PROPOSED")
        XCTAssertEqual(plan.schedules.map(\.when), ["0 19 * * 0"])
        XCTAssertEqual(plan.collections.first?.summary, "one workout")
        XCTAssertEqual(plan.skills.first?.summary, "Log from a sentence.")
    }

    func testADecidedPlanSaysWhatBecameOfIt() {
        XCTAssertEqual(IntegrationPlan(json: ["id": "p", "status": "approved"]).statusLabel, "CREATED")
        XCTAssertEqual(IntegrationPlan(json: ["id": "p", "status": "cancelled"]).statusLabel, "CANCELLED")
        XCTAssertFalse(IntegrationPlan(json: ["id": "p", "status": "approved"]).isPending)
    }
}

/// What the bug sweep found on this screen, kept fixed.
final class IntegrationsSweepTests: XCTestCase {

    private func row(_ id: String, status: String = "active", records: Int = 0) -> Integration {
        Integration(json: ["id": id, "name": id, "status": status, "record_count": records])
    }

    func testTheListNoticesMoreThanTheIDChanging() {
        // SwiftUI decides whether to redraw a row from this ==, so comparing only
        // the id meant pausing an integration never showed up until a relaunch.
        XCTAssertNotEqual(row("casino"), row("casino", status: "paused"))
        XCTAssertNotEqual(row("casino", records: 17), row("casino", records: 18))
        XCTAssertEqual(row("casino"), row("casino"))
        // Still one navigation value, so a push is not invalidated by a count.
        XCTAssertEqual(row("casino").hashValue, row("casino", records: 18).hashValue)
    }

    func testABooleanReadsAsTrueNotOne() {
        let record = IntegrationRecord(json: ["won": true, "lost": false, "hands": 12], index: 0)
        let fields = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key, $0.value) })
        XCTAssertEqual(fields["won"], "true")
        XCTAssertEqual(fields["lost"], "false")
        XCTAssertEqual(fields["hands"], "12")
    }

    @MainActor
    func testPauseReadsTheLiveCopyNotThePushedOne() async {
        // The detail screen holds the value it was pushed with forever; deriving
        // the next status from it made Pause work once and Resume never.
        let store = IntegrationsStore(api: IntegrationsAPI())
        XCTAssertNil(store.current("casino"))
    }

    func testTheRouteCarriesTheIntegrationItWasTappedIn() {
        // Both cases carry an id because the store's idea of "open" can change
        // during the push animation.
        guard case .records(let id, let collection) = IntegrationDataRoute.records("casino", "sessions")
        else { return XCTFail("not a records route") }
        XCTAssertEqual(id, "casino")
        XCTAssertEqual(collection, "sessions")
        guard case .document(let docID, let key) = IntegrationDataRoute.document("casino", "summary")
        else { return XCTFail("not a document route") }
        XCTAssertEqual(docID, "casino")
        XCTAssertEqual(key, "summary")
    }
}

/// A stack that presents more than one kind of value has to be type-erased.
///
/// The More stack used to be `[MoreDestination]`, and while Integrations lived
/// inside it a `NavigationLink(value: Integration)` could not be appended — the
/// push silently did nothing and the whole detail screen was unreachable on a
/// device, with the app building and every model test passing. Integrations owns
/// its own stack now; both are `NavigationPath`, and both stay that way.
@MainActor
final class MoreNavigationTests: XCTestCase {

    func testTheIntegrationsTabPushesItsOwnValueTypes() {
        moreUIAHost(IntegrationsPage().environment(AppRouter()))
    }

    func testEveryMoreDestinationStillOpens() {
        for destination in MoreDestination.allCases {
            moreUIAHost(MorePage(initialPath: [destination]).environment(AppRouter()))
        }
    }
}

/// Deleting parts of an integration, and the sheet that asks which parts.
final class IntegrationDeleteTests: XCTestCase {

    func testEverythingButTheSkillFilesIsOnByDefault() {
        let choice = IntegrationDeleteChoice()
        XCTAssertTrue(choice.schedules && choice.data && choice.skills && choice.space)
        // Unlinking a skill is cheap to undo; removing it is a separate decision.
        XCTAssertFalse(choice.skillFiles)
        XCTAssertFalse(choice.isEmpty)
    }

    func testTheBodyNamesEveryPartSoTheServerNeverGuesses() {
        var choice = IntegrationDeleteChoice()
        choice.data = false
        let body = choice.body
        XCTAssertEqual(body["data"] as? Bool, false)
        XCTAssertEqual(body["schedules"] as? Bool, true)
        XCTAssertEqual(body["skill_files"] as? Bool, false)
        XCTAssertEqual(body["space"] as? Bool, true)
    }

    func testTheSummarySaysExactlyWhatGoes() {
        var choice = IntegrationDeleteChoice()
        XCTAssertEqual(
            choice.summary(schedules: 2, collections: 1, documents: 1, skills: 1),
            "This removes 2 schedules, 2 data sets, 1 skill and the integration itself. "
            + "It cannot be undone.")

        choice.skillFiles = true
        XCTAssertTrue(choice.summary(schedules: 0, collections: 0, documents: 0, skills: 1)
            .contains("1 skill (and their files)"))

        choice = IntegrationDeleteChoice(schedules: false, data: true, skills: false,
                                         skillFiles: false, space: false)
        XCTAssertEqual(choice.summary(schedules: 0, collections: 3, documents: 0, skills: 0),
                       "This removes 3 data sets. It cannot be undone.")
    }

    func testNothingSelectedIsNothingToDo() {
        let choice = IntegrationDeleteChoice(schedules: false, data: false, skills: false,
                                             skillFiles: false, space: false)
        XCTAssertTrue(choice.isEmpty)
        XCTAssertEqual(choice.summary(schedules: 2, collections: 2, documents: 0, skills: 1),
                       "Nothing selected.")
    }

    func testOneConfirmationValueDrivesEveryRow() {
        let collection = IntegrationCollection(json: ["name": "sessions", "count": 18])
        XCTAssertEqual(IntegrationConfirm.collection(collection).id, "collection:sessions")
        XCTAssertEqual(IntegrationConfirm.document(
            IntegrationDocument(json: ["key": "summary"])).id, "document:summary")
        XCTAssertEqual(IntegrationConfirm.skill(
            IntegrationSkill(json: ["name": "gym-logger"])).id, "skill:gym-logger")
    }
}

/// The conversation behind the + button.
///
/// The conversation itself is an ordinary `ChatStore` now — this covers the two
/// things the sheet adds: reading the transcript for what was built, and knowing
/// when the agent has said it is done.
final class IntegrationSetupTests: XCTestCase {

    private func card(_ tool: String, _ args: [String: JSONValue]) -> SetupCard? {
        SetupCard(toolName: tool, args: args)
    }

    private func tool(_ name: String, _ args: [String: JSONValue] = [:],
                      result: String? = nil, done: Bool = true) -> ToolInvocation {
        ToolInvocation(name: name, args: args, result: result, done: done)
    }

    func testTheToolsThatBuildSomethingBecomeCards() {
        let made = card("integration_create", ["name": .string("Gym Sessions"),
                                               "description": .string("Logs workouts.")])
        XCTAssertEqual(made?.kind, .integration)
        XCTAssertEqual(made?.spaceID, "gym-sessions")   // the id the server will slug

        let data = card("registry_append", ["space": .string("gym"),
                                            "collection": .string("sessions")])
        XCTAssertEqual(data?.kind, .data)
        XCTAssertEqual(data?.name, "sessions")
        XCTAssertEqual(data?.spaceID, "gym")

        let schedule = card("cronjob", ["action": .string("create"),
                                        "name": .string("gym-weekly"),
                                        "schedule": .string("0 19 * * 0"),
                                        "integration": .string("gym")])
        XCTAssertEqual(schedule?.kind, .schedule)
        XCTAssertEqual(schedule?.detail, "0 19 * * 0")

        let skill = card("skill_manage", ["action": .string("create"),
                                          "name": .string("gym-logger"),
                                          "category": .string("productivity")])
        XCTAssertEqual(skill?.kind, .skill)
    }

    func testPlumbingDoesNotEarnACard() {
        XCTAssertNil(card("registry_query", ["space": .string("gym"),
                                             "collection": .string("sessions")]))
        XCTAssertNil(card("skills_list", [:]))
        XCTAssertNil(card("cronjob", ["action": .string("list")]))
        XCTAssertNil(card("skill_manage", ["action": .string("delete"),
                                           "name": .string("gym-logger")]))
        XCTAssertNil(card("registry_append", ["space": .string("gym")]))
    }

    func testTheIDTheSheetInfersMatchesTheOneTheServerWouldMake() {
        XCTAssertEqual(SetupCard.slug("Gym Sessions"), "gym-sessions")
        XCTAssertEqual(SetupCard.slug("  Casino Earnings!  "), "casino-earnings")
        XCTAssertEqual(SetupCard.slug("Market & Stocks"), "market-stocks")
    }

    @MainActor
    func testItLearnsWhichSpaceIsBeingBuiltFromTheTranscript() {
        let store = IntegrationSetupStore()
        XCTAssertNil(store.createdSpaceID)

        var message = ChatMessage(role: .assistant, blocks: [])
        message.startTool(tool("integration_create", ["name": .string("Gym Sessions")]))
        store.noticeReady(in: [message])
        // Without this, backing out cannot offer to remove what was made.
        XCTAssertEqual(store.createdSpaceID, "gym-sessions")
        XCTAssertNil(store.finished)
    }

    @MainActor
    func testOnlyTheAgentSayingSoEndsTheConversation() {
        let store = IntegrationSetupStore()
        var message = ChatMessage(role: .assistant, blocks: [])

        // A call still running is not a finished integration.
        message.startTool(tool("integration_ready", result: #"{"ok": true, "space": "gym"}"#,
                               done: false))
        store.noticeReady(in: [message])
        XCTAssertNil(store.finished)

        message.completeTool(name: "integration_ready",
                             result: #"{"ok": true, "space": "gym-sessions"}"#)
        store.noticeReady(in: [message])
        XCTAssertEqual(store.finished?.spaceID, "gym-sessions")
    }

    func testTheSpaceIDIsReadOutOfWhatTheToolConfirmed() {
        let confirmed = ToolInvocation(name: "integration_ready",
                                       result: #"{"ok": true, "space": "gym-sessions", "name": "Gym"}"#)
        XCTAssertEqual(IntegrationSetupStore.spaceID(inResultOf: confirmed), "gym-sessions")
        XCTAssertNil(IntegrationSetupStore.spaceID(inResultOf:
            ToolInvocation(name: "integration_ready")))
    }
}


/// One conversation view, used everywhere a conversation is shown.
///
/// The setup sheet started as a hand-rolled transcript — its own bubbles, its own
/// composer, its own scrolling — while the real chat sat next to it with markdown,
/// tool cards and streaming already working. Both are `ChatConversationView` now,
/// and nothing should quietly grow a second one.
@MainActor
final class ChatConversationReuseTests: XCTestCase {

    func testTheChatTabAndTheSetupSheetRenderTheSameConversation() {
        moreUIAHost(ChatConversationView(store: ChatStore.production()))
        moreUIAHost(IntegrationSetupSheet(onFinish: {}))
        moreUIAHost(ChatPage().environment(AppRouter()))
    }

    func testAHostCanReplaceTheComposerAndTheEmptyState() {
        // The two things a screen needs to change: what fills an empty transcript,
        // and a way out when there is nothing left to say.
        moreUIAHost(
            ChatConversationView(store: ChatStore.production(),
                                 placeholder: "Tell Jarvis what to track…") {
                Text("done")
            }
        )
        moreUIAHost(
            ChatConversationView(store: ChatStore.production()) { _ in
                Text("nothing here yet")
            }
        )
    }
}

/// Forms the agent draws in the conversation.
@MainActor
final class ChatFormCardTests: XCTestCase {

    private func form(_ extra: JSONObject = [:]) -> ChatForm {
        ChatForm(json: [
            "id": "f1", "title": "Gym Sessions", "intro": "A few details.",
            "submit_label": "Create", "status": "open",
            "fields": [
                ["key": "name", "label": "What should I call it?", "type": "text",
                 "required": true, "placeholder": "Gym Sessions"],
                ["key": "cadence", "label": "How often?", "type": "choice",
                 "options": ["Daily", "Weekly"]],
                ["key": "notify", "label": "Tell me when it runs?", "type": "toggle"],
            ],
        ].merging(extra) { _, new in new })
    }

    func testTheCardDrawsWhatTheAgentAskedFor() {
        let drawn = form()
        XCTAssertEqual(drawn.submitLabel, "Create")
        XCTAssertEqual(drawn.fields.map(\.kind), [.text, .choice, .toggle])
        XCTAssertEqual(drawn.fields[1].options, ["Daily", "Weekly"])
        XCTAssertTrue(drawn.fields[0].required)
        XCTAssertFalse(drawn.isAnswered)
    }

    func testAnUnknownFieldTypeFallsBackToABox() {
        let odd = ChatForm(json: ["id": "f", "title": "T",
                                  "fields": [["key": "a", "label": "A", "type": "slider"]]])
        XCTAssertEqual(odd.fields.first?.kind, .text)
    }

    func testAnAnsweredFormKeepsWhatWasEntered() {
        // Scrolling back should show what you said, not an empty form.
        let done = form(["status": "answered",
                         "values": ["name": "Gym", "cadence": "Weekly", "notify": true]])
        XCTAssertTrue(done.isAnswered)
        XCTAssertEqual(done.shownValue(for: done.fields[0]), "Gym")
        XCTAssertEqual(done.shownValue(for: done.fields[2]), "Yes")
        let blank = form(["status": "answered", "values": [:]])
        XCTAssertEqual(blank.shownValue(for: blank.fields[0]), "—")
    }

    func testTheFormIDComesOutOfTheToolThatAskedForIt() {
        let tool = ToolInvocation(
            name: "form_ask",
            result: #"{"ok": true, "form_id": "abc123def456", "card": {"kind": "form"}}"#)
        XCTAssertEqual(ChatForm.formID(in: tool), "abc123def456")
        XCTAssertNil(ChatForm.formID(in: ToolInvocation(name: "form_ask")))
        // Another tool is never a form, whatever its result happens to contain.
        XCTAssertNil(ChatForm.formID(in: ToolInvocation(
            name: "registry_put", result: #"{"form_id": "nope"}"#)))
    }

    func testItRendersInAConversation() {
        moreUIAHost(ChatFormCard(formID: "f1", onSubmit: { _ in }))
    }
}

/// A skill, in full, when you tap its row.
final class IntegrationSkillViewTests: XCTestCase {

    func testTheFrontMatterIsNotPartOfWhatTheSkillSays() {
        // It is metadata, and the header above already shows the parts worth reading.
        let raw = """
        ---
        name: casino-earnings-tracker
        integration: casino
        description: Log casino sessions.
        ---

        # Casino earnings

        Use the ledger.
        """
        let skill = SkillDetail(json: ["name": "casino-earnings-tracker", "content": raw])
        XCTAssertTrue(skill.markdown.hasPrefix("# Casino earnings"))
        XCTAssertFalse(skill.markdown.contains("integration: casino"))
    }

    func testABodyWithNoFrontMatterIsLeftAlone() {
        let plain = "# Just a skill\n\nDo the thing."
        XCTAssertEqual(SkillDetail.withoutFrontMatter(plain), plain)
        // An opening fence that never closes is not front matter either.
        let unclosed = "---\nname: x\n\n# Body"
        XCTAssertEqual(SkillDetail.withoutFrontMatter(unclosed), unclosed)
    }

    func testItReadsWhatTheEndpointReturns() {
        let skill = SkillDetail(json: [
            "name": "gym-logger", "description": "Log a workout.",
            "skill_dir": "/root/.jarviscopilot/skills/productivity/gym-logger",
            "tags": ["fitness", "logging"],
            "linked_files": ["reference.md": "…", "script.py": "…"],
            "content": "# Gym logger",
        ])
        XCTAssertEqual(skill.tags, ["fitness", "logging"])
        XCTAssertEqual(skill.linkedFiles.map(\.name), ["reference.md", "script.py"])
        XCTAssertTrue(skill.path.hasSuffix("gym-logger"))
    }

    @MainActor
    func testTheRowOpensIt() {
        moreUIAHost(IntegrationSkillView(name: "casino-earnings-tracker"))
    }
}

"""Skills and tools first: the server finds the skill (or on-demand tool) that
fits a message and nudges the model to use it — a model that only "sees" the
skills catalogue in its prompt often improvises instead."""
import json

from agent import skill_matcher as sm
from agent.skill_matcher import match

SKILLS = [
    {"name": "morning-brief",
     "description": "Use when Pranav asks for a morning brief, daily briefing, start-my-day recap, or wants a "
                    "spoken overview covering weather, today's tasks, news and stock-market updates.",
     "tags": ["briefing", "morning", "weather", "calendar", "news", "stocks", "voice"],
     "triggers": ["morning breeze", "morning beach", "brief me"]},
    {"name": "shopping-list-manager", "description": "Add, remove and review items on the shopping list.",
     "tags": ["shopping", "groceries"]},
    {"name": "google-workspace", "description": "Read and send Gmail, manage Google Calendar and Drive.",
     "tags": ["email", "calendar", "drive"]},
    {"name": "maps", "description": "Open directions in Maps from the current location.", "tags": ["navigation", "directions"]},
] + [  # a realistic corpus: words are rare across many skills
    {"name": f"filler-{i}", "description": d, "tags": t} for i, (d, t) in enumerate([
        ("Run code reviews on pull requests.", ["github"]),
        ("Train and evaluate machine learning models.", ["mlops"]),
        ("Write and edit documents in Notion.", ["notes"]),
        ("Control smart-home lights and scenes.", ["home"]),
        ("Generate images from prompts.", ["creative"]),
        ("Search arXiv for research papers.", ["research"]),
        ("Track packages and deliveries.", ["shopping"]),
        ("Plan workouts and log sets.", ["fitness"]),
    ])
]


def test_morning_brief_phrasings():
    for text in ["Can you give me the morning brief?", "morning breeze please", "brief me",
                 "give me my daily briefing", "Morning brief"]:
        assert match(text, SKILLS)["skill"] == "morning-brief", text


def test_other_skills_match_their_own_requests():
    assert match("add milk to my shopping list", SKILLS)["skill"] == "shopping-list-manager"
    assert match("open directions to the airport", SKILLS)["skill"] == "maps"


def test_unrelated_text_matches_nothing():
    for text in ["what is 1 cup in ml", "hello, are you there?", "what model are you?",
                 "what's the weather", "don't worry about it"]:
        assert match(text, SKILLS)["skill"] is None, text


def test_an_ambiguous_message_names_no_skill():
    # Two skills fit about equally: no confident pick, no hint.
    twins = SKILLS + [{"name": "voice-notes", "description": "Take a quick note.", "tags": ["notes"]},
                      {"name": "quick-notes", "description": "Take a quick note.", "tags": ["notes"]}]
    assert match("take a quick note", twins)["skill"] is None


def test_no_hint_when_skill_already_loaded():
    assert match("morning brief", SKILLS, loaded={"morning-brief"})["skill"] is None


def test_tools_named_from_the_on_demand_catalogue():
    tools = [{"name": "device_set_alarm", "description": "Set an alarm on the iPhone."},
             {"name": "browser_navigate", "description": "Open a web page in the browser."}]
    out = match("set an alarm for 7 am", SKILLS, tools)
    assert out["tools"] == ["device_set_alarm"]


def test_skills_already_loaded_are_read_from_history_including_the_bridge():
    history = [
        {"role": "assistant", "tool_calls": [{"function": {"name": "skill_view",
                                                           "arguments": json.dumps({"name": "maps"})}}]},
        {"role": "assistant", "tool_calls": [{"function": {"name": "tool_call", "arguments": json.dumps(
            {"name": "skill_view", "arguments": {"name": "morning-brief"}})}}]},
    ]
    assert sm.loaded_skills(history) == {"maps", "morning-brief"}


def test_hint_text_names_the_skill_and_the_tools():
    text = sm.hint_text({"skill": "morning-brief", "score": 9.0, "tools": ["device_set_alarm"]})
    assert "`morning-brief`" in text and "skill_view" in text
    assert "device_set_alarm" in text and "tool_search" in text
    assert sm.hint_text({"skill": None, "score": 0.0, "tools": []}) == ""


def test_manifest_lines_parse_into_tool_entries():
    manifest = "# Deferred tools\nheader\n\n## devices\n- device_set_alarm — Set an alarm.\n- device_x\n"
    assert sm.manifest_tools(manifest) == [
        {"name": "device_set_alarm", "description": "Set an alarm."},
        {"name": "device_x", "description": ""}]


def test_frontmatter_triggers_and_tags_are_read(tmp_path):
    d = tmp_path / "productivity" / "morning-brief"
    d.mkdir(parents=True)
    (d / "SKILL.md").write_text(
        "---\nname: morning-brief\ndescription: Morning brief.\nmetadata:\n  jarviscopilot:\n"
        "    tags: [briefing]\n    triggers: [morning breeze]\n---\n# Morning Brief\n")
    docs = sm.read_skill_docs([tmp_path])
    assert docs == [{"name": "morning-brief", "description": "Morning brief.",
                     "tags": ["briefing"], "triggers": ["morning breeze"]}]


def test_one_shared_word_is_coincidence_not_a_match():
    alarm = SKILLS + [{"name": "door-alarm", "description": "Arm and disarm the house alarm.", "tags": ["security"]}]
    assert match("set an alarm for 7", alarm)["skill"] is None
    assert match("arm the house alarm", alarm)["skill"] == "door-alarm"


def test_only_the_users_own_words_are_matched():
    assert sm.user_words("[Workspace::v1: /root/workspace] add milk to the list") == "add milk to the list"
    assert sm.user_words("Set an alarm.\n\n[Your active task list was preserved across context compression]\n"
                         "- brief_4. Collect news") == "Set an alarm."
    assert sm.user_words("A faster model handed this over to you. Finish it fully with your tools.\n\n"
                         "Hand-off note: plan my week") == "plan my week"

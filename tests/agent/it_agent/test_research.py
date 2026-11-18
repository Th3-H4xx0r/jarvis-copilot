"""Deep research: several queries, 3–6 sources read, a written brief; thin research gets one more round."""
import json

from agent.it_agent.model import Deps, ShellResult, ScreenResult
from agent.it_agent.research import research

BRIEF = {"summary": "Docker Desktop needs WSL2", "requirements": ["WSL2"], "route": "winget",
         "checks": ["docker --version"]}


class Fake:
    def __init__(self, replies, results=None, unreadable=()):
        self.replies, self.purposes, self.prompts = list(replies), [], []
        self.searched, self.extracted = [], []
        self.results = results or {}
        self.unreadable = set(unreadable)

    def ask(self, purpose, prompt, max_tokens):
        self.purposes.append(purpose)
        self.prompts.append(prompt)
        return self.replies.pop(0)

    def search(self, query):
        self.searched.append(query)
        return self.results.get(query, [{"url": f"https://{query.replace(' ', '-')}/{i}", "title": f"{query} {i}"}
                                        for i in range(3)])

    def extract(self, urls):
        self.extracted.append(list(urls))
        return [({"url": u, "error": "blocked"} if u in self.unreadable or "*" in self.unreadable
                 else {"url": u, "title": "t", "content": "x" * 9000}) for u in urls]

    def deps(self):
        nothing = lambda *a, **k: None  # noqa: E731
        return Deps(ask=self.ask, search=self.search, extract=self.extract,
                    shell=lambda c, t: ShellResult("ran"), admin=lambda c, w, t: ShellResult("ran"),
                    screen=lambda g: ScreenResult(True), read_screen=lambda a: "", online=lambda: True,
                    signed_in=lambda: True, wake=nothing, notify=nothing, progress=nothing,
                    should_stop=lambda: False)


def _queries(*qs):
    return json.dumps({"queries": list(qs)})


def test_research_runs_several_queries_and_reads_3_to_6():
    fake = Fake([_queries("a", "b", "c", "d"),
                 json.dumps({"read": [f"https://a/{i}" for i in range(3)] + ["https://b/0", "https://b/1"]}),
                 json.dumps(BRIEF)])
    brief = research("install Docker Desktop", {}, fake.deps())
    assert len(fake.searched) == 4 and 3 <= len(brief.sources) <= 6
    assert all(len(batch) <= 5 for batch in fake.extracted)
    assert brief.sources[0] == {"url": "https://a/0", "title": "t"}


def test_queries_and_pick_use_the_fast_model():
    fake = Fake([_queries("a", "b", "c"), json.dumps({"read": ["https://a/0", "https://a/1", "https://a/2"]}),
                 json.dumps(BRIEF)])
    research("install Docker Desktop", {}, fake.deps())
    assert fake.purposes == ["fast", "fast", "plan"]


def test_pick_outside_results_falls_back():
    fake = Fake([_queries("a", "b"), json.dumps({"read": ["https://evil/x"]}), json.dumps(BRIEF)])
    brief = research("install Docker Desktop", {}, fake.deps())
    assert [s["url"] for s in brief.sources] == ["https://a/0", "https://a/1", "https://a/2"]


def test_thin_research_runs_one_more_round():
    results = {"a": [{"url": "https://a/0", "title": "a0"}], "b": [{"url": "https://b/0", "title": "b0"}],
               "c": [{"url": "https://c/0", "title": "c0"}]}
    fake = Fake([_queries("a", "b"), json.dumps({"read": ["https://a/0", "https://b/0"]}),
                 _queries("c", "d"), json.dumps({"read": ["https://c/0"]}), json.dumps(BRIEF)],
                results=results, unreadable={"https://b/0"})
    brief = research("install Docker Desktop", {}, fake.deps())
    assert fake.searched[:2] == ["a", "b"] and "c" in fake.searched
    assert brief.summary.endswith("(only 2 sources could be read)")


def test_research_only_brief_needs_answer():
    only = {"summary": "s", "route": "read reviews", "checks": [], "research_only": True}
    fake = Fake([_queries("a", "b", "c"), json.dumps({"read": ["https://a/0", "https://a/1", "https://a/2"]}),
                 json.dumps(only), json.dumps({**only, "answer": "The ASUS ROG"})])
    brief = research("best PC under $2k?", {}, fake.deps())
    assert brief.research_only and brief.answer == "The ASUS ROG" and "research-only brief needs the answer" in fake.prompts[-1]

"""Deep research before acting: several queries, 3–6 sources read, a written brief (requirements, the route,
the checks that prove it worked)."""
from __future__ import annotations

from agent.it_agent.model import Brief, Deps, PlanError
from agent.it_agent.plans import ask_json, parse_brief, parse_pick, parse_queries
from agent.it_agent.prompts import brief_prompt, pick_prompt, queries_prompt

MIN_SOURCES = 3
MAX_SOURCES = 6
PAGE_CHARS = 6000


def _round(goal: str, queries: list, deps: Deps, tried: list) -> list:
    seen, results = set(tried), []
    for q in queries:
        for r in deps.search(q) or []:
            url = (r or {}).get("url")
            if url and url not in seen:
                seen.add(url)
                results.append(r)
    if not results:
        return []
    urls = [r["url"] for r in results]
    picked = parse_pick(deps.ask("fast", pick_prompt(goal, results), 400), urls) or urls[:MIN_SOURCES]
    picked = picked[:MAX_SOURCES]
    tried.extend(picked)
    pages = []
    for i in range(0, len(picked), 5):
        for page in deps.extract(picked[i:i + 5]) or []:
            if page and not page.get("error") and page.get("content"):
                pages.append({**page, "content": str(page["content"])[:PAGE_CHARS]})
    return pages


def research(goal: str, facts: dict, deps: Deps) -> Brief:
    try:
        queries = ask_json(deps.ask, "fast", queries_prompt(goal, facts), parse_queries, max_tokens=400)
    except PlanError:
        queries = [goal]
    tried: list = []
    pages = _round(goal, queries, deps, tried)
    if len(pages) < MIN_SOURCES:   # thin: one more round, naming what couldn't be read
        read = {p["url"] for p in pages}
        try:
            more = ask_json(deps.ask, "fast", queries_prompt(goal, facts, failed=[u for u in tried if u not in read]),
                            parse_queries, max_tokens=400)
        except PlanError:
            more = []
        pages += _round(goal, [q for q in more if q not in queries], deps, tried)
    pages = pages[:MAX_SOURCES]
    sources = [{"url": p["url"], "title": p.get("title", "")} for p in pages]
    brief = ask_json(deps.ask, "plan", brief_prompt(goal, pages, facts), lambda text: parse_brief(text, sources),
                     max_tokens=2500)
    if len(pages) < MIN_SOURCES:
        brief.summary = f"{brief.summary} (only {len(pages)} sources could be read)"
    return brief

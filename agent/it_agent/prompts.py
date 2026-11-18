"""Prompts for the IT agent (each asks for exactly the JSON the code validates in plans.py)."""
from __future__ import annotations

import json


def _facts(facts: dict) -> str:
    shown = {k: v for k, v in (facts or {}).items() if not str(k).startswith("_")}
    return json.dumps(shown) if shown else "(not known yet)"


def queries_prompt(goal: str, facts: dict, failed: list | None = None) -> str:
    retry = (f"\nThese pages couldn't be read; search differently: {', '.join(failed)}" if failed else "")
    return (f"You research a task before doing it on the user's Windows PC, like an IT support person.\n"
            f"Task: {goal}\nPC facts: {_facts(facts)}{retry}\n"
            "Write 3–5 distinct web search queries: the official docs / install guide, the system requirements, "
            "and known issues or common errors. Reply with ONLY: {\"queries\": [\"...\"]}")


def pick_prompt(goal: str, results: list) -> str:
    listed = "\n".join(f"- {r.get('url')} — {r.get('title', '')}" for r in results)
    return (f"Task: {goal}\nSearch results:\n{listed}\n"
            "Pick 3–6 URLs to read, official sources first (the vendor's docs, Microsoft Learn), then trusted "
            "guides. Only URLs from the list. Reply with ONLY: {\"read\": [\"...\"]}")


def brief_prompt(goal: str, pages: list, facts: dict) -> str:
    body = "\n\n".join(f"### {p.get('title') or p.get('url')} ({p.get('url')})\n{p.get('content', '')}" for p in pages)
    return (f"Task: {goal}\nPC facts: {_facts(facts)}\nWhat you read:\n{body}\n\n"
            "Write the brief an IT support person would before starting. Reply with ONLY this JSON:\n"
            "{\"summary\": \"2–4 sentences\", \"requirements\": [\"...\"], \"route\": \"how you'll do it "
            "(prefer the terminal: winget / PowerShell)\", \"checks\": [\"commands that prove it worked\"], "
            "\"research_only\": false, \"answer\": \"\"}\n"
            "Set research_only true (and write the answer) only when the task is a question to answer and "
            "nothing has to be done on the PC.")

#!/usr/bin/env python3
"""Can Live Jarvis actually tell these voices apart? Measure, don't guess.

Speaker identification looked like it was working long after it had stopped
being useful: every segment got a label, new voices were minted, the Voices list
filled up — and the same person was split across two voices whose centroids
scored 0.2492 against each other while one of them scored 0.2696 against
Jarvis's own text-to-speech. Labels are not evidence. The number that matters is
whether same-speaker pairs score higher than different-speaker pairs, and by
enough of a margin to sit a threshold in.

It reports SEGMENT SPANS first, because that is where the fault turned out to
be. The phone's voice-activity gates were absolute values in a room that sits
above them, so an utterance only ever ended at the 15 s chunking cap and every
segment was stamped 15.00-15.08 s whatever was said. The server slices its
voiceprint audio from those timestamps, so it was embedding fifteen seconds of
room tone. A run where most spans are pinned at the cap is not a run whose
similarity numbers mean anything, and this says so before it says anything else.

Read-only: it opens live.db, re-embeds stored audio and prints. It writes
nothing, so it is safe to run against a live recording.

    python3 scripts/live_identity_report.py                 # the newest session
    python3 scripts/live_identity_report.py --session <id>
    python3 scripts/live_identity_report.py --json

Run it where live.db and the model are — on the server, in its venv:

    cd /root/JarvisCopilot/webui && ../.venv/bin/python scripts/live_identity_report.py
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from api import live_store, live_voiceprint, live_ws  # noqa: E402

# The chunking cap the phone falls back to when its gates never close. A span
# within a frame of it is the signature of that bug, not a real utterance.
CAP_MS = 15000
CAP_SLACK_MS = 250

# Above this share of spans sitting at the cap, the segmenter is chunking
# rather than detecting and no similarity number below is worth reading.
CAP_SHARE_ALARM = 0.34

# Cheap enough to run on a whole conversation, bounded so a long one does not
# turn this into a batch job.
MAX_SEGMENTS = 80


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--session", default="",
                        help="live session id (default: the newest)")
    parser.add_argument("--limit", type=int, default=MAX_SEGMENTS,
                        help=f"how many segments to embed (default {MAX_SEGMENTS})")
    parser.add_argument("--json", action="store_true",
                        help="machine-readable output instead of prose")
    args = parser.parse_args(argv)

    session_id = args.session or newest_session()
    if not session_id:
        print("No live sessions in this database.")
        return 1

    rows = live_store.segments_after(session_id)
    report = {
        "live_session_id": session_id,
        "segments": len(rows),
        "spans": span_report(rows),
        "speakers": speaker_report(),
    }
    if not live_voiceprint.available():
        report["pairs"] = {"error": "the voiceprint model is not loadable here"}
    else:
        report["pairs"] = pair_report(session_id, rows[:max(1, args.limit)])

    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_report(report)
    return 0


def newest_session() -> str:
    with live_store.connect() as conn:
        row = conn.execute("SELECT id FROM live_session"
                           " ORDER BY started_at DESC LIMIT 1").fetchone()
    return str(row["id"]) if row else ""


def span_report(rows) -> dict:
    """How long the utterances were, and how many are pinned at the cap."""
    spans = [int(r["ts_end_ms"] or 0) - int(r["ts_start_ms"] or 0) for r in rows]
    spans = [s for s in spans if s > 0]
    if not spans:
        return {"count": 0}
    pinned = sum(1 for s in spans if abs(s - CAP_MS) <= CAP_SLACK_MS)
    return {
        "count": len(spans),
        "median_ms": int(statistics.median(spans)),
        "min_ms": min(spans),
        "max_ms": max(spans),
        "at_cap": pinned,
        # The one number to read first.
        "at_cap_share": round(pinned / len(spans), 3),
    }


def speaker_report() -> dict:
    """Centroid-to-centroid cosines: the matrix the labels are derived from."""
    centroids = live_voiceprint.centroids() if live_voiceprint.available() else {}
    names = {s["id"]: (s.get("name") or s.get("kind") or "?")
             for s in live_store.list_speakers()}
    ids = sorted(centroids)
    pairs = []
    for i, left in enumerate(ids):
        for right in ids[i + 1:]:
            pairs.append({
                "a": left[:8], "a_name": names.get(left, "?"),
                "b": right[:8], "b_name": names.get(right, "?"),
                "cosine": round(live_voiceprint.cosine(centroids[left],
                                                       centroids[right]), 4),
            })
    pairs.sort(key=lambda p: -p["cosine"])
    return {"count": len(ids), "pairs": pairs}


def pair_report(session_id: str, rows) -> dict:
    """Same-speaker vs different-speaker cosines over this session's own audio.

    Re-embedded from the stored chunks rather than read from
    `speaker_embedding`: the point is to measure what the audio supports, not
    to replay the decisions that were already made from it.
    """
    vectors = []
    for row in rows:
        speaker = str(row["speaker_id"] or "")
        if not speaker:
            continue
        got = live_ws.pcm_for_range(session_id, int(row["ts_start_ms"] or 0),
                                    int(row["ts_end_ms"] or 0),
                                    str(row["device_id"] or ""))
        if not got:
            continue
        pcm, rate = got
        vec = live_voiceprint.embed(pcm, rate)
        if vec:
            vectors.append((speaker, vec))

    same, different = [], []
    for i, (left_id, left) in enumerate(vectors):
        for right_id, right in vectors[i + 1:]:
            score = live_voiceprint.cosine(left, right)
            (same if left_id == right_id else different).append(score)

    out = {"embedded": len(vectors), "same_pairs": len(same),
           "different_pairs": len(different)}
    out.update(agreement(vectors))
    if same:
        out["same_mean"] = round(statistics.fmean(same), 4)
        out["same_min"] = round(min(same), 4)
    if different:
        out["different_mean"] = round(statistics.fmean(different), 4)
        out["different_max"] = round(max(different), 4)
    if same and different:
        # The only number that decides whether a threshold can exist: the gap
        # between the worst same-speaker pair and the best different-speaker
        # one. Negative means the two populations overlap and NO threshold
        # separates them, however the constants are tuned.
        out["margin"] = round(min(same) - max(different), 4)
    return out


def agreement(vectors) -> dict:
    """How often a segment's own audio best matches the voice it was filed under.

    This is the question "is identification working", and it is NOT the same
    question as whether two voices are far apart. Two recordings of one person
    at different mic distances land in two voices that score badly against each
    other — and every segment still matches its own voice perfectly. That is a
    person to MERGE, not a broken recogniser, and reading the centroid matrix
    alone cannot tell the two cases apart.
    """
    centroids = live_voiceprint.centroids()
    if not centroids:
        return {}
    agreed = 0
    checked = 0
    for speaker, vec in vectors:
        if speaker not in centroids:
            continue
        checked += 1
        best = max(centroids, key=lambda k: live_voiceprint.cosine(vec, centroids[k]))
        if best == speaker:
            agreed += 1
    if not checked:
        return {}
    return {"filed_checked": checked, "filed_agreed": agreed,
            "filed_share": round(agreed / checked, 3)}


def _low_centroid_pairs(speakers: dict) -> bool:
    """Whether any two voices on file score below the confirm threshold.

    With more than one voice that is the normal, healthy case — they are
    different people. It only becomes the merge hint when every segment is
    ALSO filed correctly, which is what the caller checks first.
    """
    return any(p["cosine"] < live_voiceprint.SIM_CONFIRM
               for p in speakers.get("pairs", []))


def print_report(report: dict) -> None:
    print(f"Live session {report['live_session_id'][:8]} — "
          f"{report['segments']} segments")
    spans = report["spans"]
    print()
    print("Utterance spans")
    if not spans.get("count"):
        print("  nothing with a usable span")
    else:
        print(f"  median {spans['median_ms'] / 1000:.2f}s   "
              f"min {spans['min_ms'] / 1000:.2f}s   "
              f"max {spans['max_ms'] / 1000:.2f}s")
        share = spans["at_cap_share"]
        note = ("the segmenter is CHUNKING, not detecting — nothing below means "
                "anything" if share >= CAP_SHARE_ALARM else "healthy")
        print(f"  at the {CAP_MS // 1000}s cap: {spans['at_cap']}"
              f"/{spans['count']} ({share:.0%}) — {note}")

    speakers = report["speakers"]
    print()
    print(f"Voices on file: {speakers['count']}")
    for pair in speakers["pairs"][:10]:
        print(f"  {pair['a']} ({pair['a_name']}) <-> {pair['b']} "
              f"({pair['b_name']}): {pair['cosine']:.4f}")

    pairs = report["pairs"]
    print()
    print("This session's own audio, re-embedded")
    if pairs.get("error"):
        print(f"  {pairs['error']}")
        return
    print(f"  embedded {pairs['embedded']} segments")
    if "same_mean" in pairs:
        print(f"  same speaker:       mean {pairs['same_mean']:.4f}   "
              f"worst {pairs['same_min']:.4f}   ({pairs['same_pairs']} pairs)")
    if "different_mean" in pairs:
        print(f"  different speakers: mean {pairs['different_mean']:.4f}   "
              f"best {pairs['different_max']:.4f}   "
              f"({pairs['different_pairs']} pairs)")
    if "margin" in pairs:
        margin = pairs["margin"]
        verdict = ("separable — a threshold fits in the gap" if margin > 0
                   else "NOT separable — the two populations overlap, so no "
                        "threshold can tell these voices apart")
        print(f"  margin: {margin:+.4f} — {verdict}")
        print(f"  (the shipped thresholds are confirm >= "
              f"{live_voiceprint.SIM_CONFIRM}, new voice below "
              f"{live_voiceprint.SIM_NEW_SPEAKER})")
    if "filed_share" in pairs:
        share = pairs["filed_share"]
        print(f"  filed correctly: {pairs['filed_agreed']}"
              f"/{pairs['filed_checked']} segments best-match the voice they "
              f"were filed under ({share:.0%})")
        if share >= 0.9 and _low_centroid_pairs(speakers):
            print("  → identification is working. Two voices that score badly "
                  "against each other while every segment matches its own are "
                  "one person recorded two ways — merge them in Voices.")


if __name__ == "__main__":
    raise SystemExit(main())

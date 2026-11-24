# 2026-11-23 — computer control: "turn on my PC and launch Warzone" took two tries

1. [ ] **Launching a game right after waking the PC stops on the launcher page and never presses Play** (his words: "it always seems to end up on the battle net page and it doesn't click play"). Must stay general, nothing per app ("make sure nothing is hard-coded just for this warzone task … it should work for any type of task").
   - Found (agent.log 04:48 UTC): wake 9 s + unlock 2 s fine; Battle.net opened on the Call of Duty page but was still "Connecting…" / "Loading account information". Play did nothing yet. The run clicked Play 3× and a sign-in notice 3×, re-planned twice, stopped after ~15 s. 2 min later one click worked.
   - Found: a "wait" move was a 0.5 s pause, so nothing in the loop could wait for an app to get ready.
   - Found: the end check said "wait for Battle.net to finish connecting", but the loop re-planned clicks and gave up.
   - Found: "Play" matched inside "…in order to play." (a substring test), so the fast model clicked the notice and the step counted as done.
   - Found (23:48 run): the screenshot model was the chat model (GPT Terra) at its usage limit: a 429 on every call, 21 s, then stuck.
   - Found (00:01 runs): the Pod wake didn't bring the PC up. Already handled by the PC power button work (2026-11-23-pc-power-button.md).
   - ✅ Fixed in 5689ded49: a wait watches the screen until it changes (1.5 s looks, ≤15 s a move, ≤90 s a run, not counted against the move-time budget). The end check reports busy and waits, then plans the rest from the ready screen. The models are told to wait while an app loads. Whole-word, short-label button matching; a click on a message isn't done until the screenshot model looks. A screenshot model whose provider fails hands over to the planning model.
   - ✅ 272 computer tests pass. Deployed: webui restarted 05:06:59 UTC (healthy).
   - [ ] Live check: next "turn on my PC and launch <game>" from a cold PC. agent.log should show `Computer wait:` lines, then a click on Play.

2. [x] **Server disk full** (44 GB, 0 free: `sqlite3.OperationalError: database or disk is full`, SSH routes dropped).
   - ✅ He grew the disk to 69 GB (24 GB free) and restarted Jarvis.
   - Biggest now: /root/.jarviscopilot 9.3 GB (state.db 3.6 GB, up from 2.4 GB on 10-31), /root/.cache 4.6 GB, /root/codingprojects 4.3 GB, /root/.claude 2.2 GB, journal 0.7 GB; ~17 GB is outside /root.

## Shipped
- 5689ded49 fix(computer): wait for an app that is still getting ready instead of clicking it and giving up

## For you
- Next time, just ask for a game from a cold PC as usual. The run now waits up to 90 s for a launcher to finish signing in.

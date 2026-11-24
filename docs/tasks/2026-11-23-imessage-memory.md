# 2026-11-23 — iMessage memory: live tracking "doesn't really work", backfills skip most messages

1. [ ] **No new message facts; backfills store little and "skip" a lot** (his words: "it's not even running after new messages and it's not showing me new message facts … even those [backfills] have been getting so many skipped messages and not many even stored").
   - Found: live tracking does arrive (every active chat's newest message matched a burst on the server). The break was after that.
   - Found (root cause): since 11-22 07:25 UTC every extraction hit a 429 usage limit. The memory model was GPT Luna on his ChatGPT Plus plan (weekly window). Each failure was marked no_extract, its messages were deleted and never retried. 39 conversations 11-21 → 11-24 were lost this way (25 older ones from October too).
   - Found: a backfill counts messages already inside a conversation record as "skipped" (71,301 in the 03-24 → now run). That includes no_extract records, so backfills never redid the lost ones. The phone said "skipped"; the web already said "already remembered".
   - Found: the memory map pass made ~11,400 failed calls in two days, and 8 chat turns lost their memories ("skipping turn").
   - Decision (his, via picker): "I should set this model" → a backup-model setting he picks; unset = wait. He also switched the memory model to Claude Haiku 5.5 himself.
   - ✅ e5a510b0f4: guarded memory calls (a limited model is benched until its reset, the backup covers, else ModelPaused with no network call); iMessage failures stay queued, only unreadable replies ×3 give up; chat turns wait in a saved queue; one log line per pause; paused line + backup picker on web and iPhone; "already remembered" on the phone.
   - ✅ 358 memory/iMessage/web tests pass (1 failure in test_fixes.py also fails without this change); iOS: 50 tests passed on the simulator (helper run).
   - ✅ Server deployed: webui restarted 05:36:13 UTC; his running backfill b5d0dcc4f098 resumed on its own (1,461 → 1,236 waiting in 90 s).
   - ✅ iPhone build 263280538 published (backup picker, paused line, "already remembered").
   - ✅ b5d0dcc4f098 finished: 557 conversations stored from 4,512 new messages.
   - ✅ Recovery: 64 no_extract records cleared (13 chats; DB backup imessage_memory.db.bak-2026-11-24); backfill bb1178e934d9 from 2026-01-03, uploaded by the Mac in 3.5 min (3,116 new messages), analyzing.
   - ✅ Recovery backfill finished: 67 conversations stored.

2. [ ] **"still can't change the model here"** (his screenshot of the iMessage memory page, MODEL section with only "change it in Long-term Memory").
   - ✅ f8c9322eca: "Memory model" + "While it's at its limit, use" pickers on the iMessage page (iPhone + web), same setting as Long-term Memory, footnote "Also used for chat memories and the memory map."; web deployed 05:53:57 UTC.
   - ✅ iPhone build 263280554 published.

## Shipped
- e5a510b0f4 fix(memory): a memory model at its usage limit loses nothing; his backup model covers
- f8c9322eca feat(imessage-memory): change the memory model right on the iMessage page

## For you
- Optional: Long-term Memory → "While it's at its limit, use" if you ever switch back to a plan model.

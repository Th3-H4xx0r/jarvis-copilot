# 2026-10-17 — Car commands: a spoken yes instead of Face ID

He said: "it's a bit annoying to do face id on phone each time to confirm car actions (ALL actions) -> this is
regarding the voice route only, not from actually doing these steps in the UI. When I ask in voice to unlock or
start car and all this, it should just ask for a confirmation then do the actions, rather than sending the
command to validate on the phone. DO this for all car related actions."

His picks: **the server checks his words** (not the model); **every voice path** (phone Voice, CarPlay,
Mac / web voice, Pod, every other); **typed chat asks too**. Then "work directly and implement this then
parallel bug sweep then push to all devices".

My calls (said in chat, he didn't object): the yes has to be his very next message, within 2 minutes; one
question can cover several commands; Stop stays instant; the Car page keeps hold-to-fire + Face ID; runs with
nobody to answer (scheduled jobs, subagents, background jobs, Live passes) keep the Face ID card; the door
alarm keeps Face ID; the Home Assistant guard stays.

- [x] **1. Server: toyota_command asks, his next message's yes runs it** (52e3504663)
  - Built: plugins/toyota/confirm.py — toyota_command in a chat/voice turn returns the question
    ("Unlock the car?") and sends nothing; the toyota plugin's turn-start hook reads his next message itself
    and a plain yes runs it before Jarvis answers. Unattended runs fall back to the Face ID card.
  - ✅ 162 Toyota tests pass (54 new); the real plugin loader registers the hook.
- [x] **2. Bug sweep** — two reviewers (logic/security; every voice path reaches the check). Fixed:
  - A yes to some *other* question ran a command queued behind it → the reply he heard must ask about it.
  - "Okay, lock it" counted as yes to "Unlock the car?" → only words naming the asked command may follow.
  - TUI (new task id every turn) never matched → questions keyed by chat (session id).
  - Telegram/iMessage voice-note + reply-quote wrappers hid the yes → unwrapped (group "[Name] yes" stays out).
  - /background (`bg_`) and unattended gateway nodes asked a question nobody could answer → Face ID card.
  - Pod echo ("car? Yes") → leading echo of the question is dropped; clarify-tool asks → told to ask in the reply.
  - Wait for the car before Jarvis answers: 25 s → 15 s, then "on its way".
  - ✅ 195 Toyota tests + the agent loop/HA tool (604 total) pass; the 37 failures in tests/agent are the same on
    a clean HEAD (not this change).
- [x] **3. Deploy (server; no phone/Mac changes needed)** — jc-hermes on 52e350466, webui 04:45:01 UTC, gateway
  04:45:24 UTC (Telegram, Photon, Home Assistant reconnected).
- [ ] **4. CarPlay Talk widget keeps listening after "Unlock the car?"** — its one-shot turn closes the mic after
  any reply, so today he taps Talk again to say yes. Asked the CarPlay session (it has those files open).
  - Built by the CarPlay session (jarvis-copilot-41): a one-shot reply ending in "?" listens for one more answer,
    then closes as before (10 s silence close still applies); tests green. Ships with its round-5 commit — tick
    once that's on the phone.

## Shipped
- Voice (phone, CarPlay voice, Mac, web, Pod) and typed chat (app, web, Telegram, iMessage): "unlock my car" →
  "Unlock the car?" → "yes" → done. No Face ID card.

## For you
- Try one harmless one first: "Jarvis, sound the buzzer" → "Sound the buzzer?" → "Yes".
- Known limits: the on-device voice lane (off by default) answers "yes" on the phone itself; a Route that sends
  "yes" to a Computer node runs the command but may not say so.

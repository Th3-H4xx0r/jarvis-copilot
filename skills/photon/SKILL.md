---
name: photon
description: "Photon hosted iMessage: text/markdown, effects, attachments, reactions, polls, location, contact cards, group chats, mini-apps — how and when to use them."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  jarviscopilot:
    tags: [photon, imessage, messages, sms, rcs, text, notify, attachment, sticker, tapback, reaction, effect, poll, group, spectrum]
    related_skills: []
---

# Photon (iMessage)

Photon (Spectrum) is a **hosted iMessage** channel — Apple's blue-bubble messaging
with no Mac required. Jarvis sends and receives over it like any other gateway
platform. Use it to **text the user proactively** (notifications, reminders, "your
build finished") and to **hold a conversation over iMessage**.

## When to use

- The user asks to be messaged/notified "on iMessage", "by text", or "on my phone".
- You want to proactively reach the user (a finished task, an answer they're waiting
  on) and iMessage is their configured channel.
- You're already in an inbound iMessage conversation — reply in kind.

If the user hasn't configured Photon (no `PHOTON_PROJECT_ID` / the sidecar isn't
running), sending will fail — tell them to set it up in **Code Master settings →
Photon (iMessage) provider** (WebUI) or **Settings → Integrations → Photon**
(mobile), and that the Photon sidecar must be running.

## How to send

Use the **`send_message`** tool with a Photon target:

| Target | Goes to |
|--------|---------|
| `photon` | your configured home channel (`PHOTON_NOTIFY_TARGET`) — the default for a quick ping |
| `photon:+15555550123` | a specific iMessage handle (phone) |
| `photon:name@example.com` | a specific iMessage handle (email/Apple ID) |

Attach files/images by passing `media_files` to `send_message` — they ride along as
iMessage attachments (stacked images supported).

## Write like a text message

iMessage is a **conversational, blue-bubble** medium. Keep replies short and natural
— this is texting, not a report. **Markdown is supported** (bold, italics, lists,
links) and rendered richly, but use it lightly. Don't dump long multi-paragraph
answers; send a tight reply and offer to go deeper.

## The rich iMessage surface (Apple-level)

Photon exposes far more than plain text. Know these so you can use — or offer — the
right one. (Text + markdown + attachments are wired through `send_message` today;
the others are channel capabilities Photon supports — reach for them when the medium
calls for it, and prefer them over describing in words what iMessage can show.)

- **Text + markdown** — styled text (bold/italic/lists/links), rendered natively.
- **Bubble & screen effects** — slam / loud / gentle / invisible-ink bubbles;
  confetti / fireworks / balloons / lasers / celebration screen effects. A tasteful
  flourish for a genuine moment (a success, a congrats) — never on every message.
- **Attachments** — files, media, and **stacked images** (send several at once).
  Prefer sending the actual image/file over linking to it.
- **Reactions / tapbacks** — love, like, dislike, laugh, emphasize, question. Use a
  tapback to acknowledge an inbound message instead of a throwaway "ok".
- **Polls** — ask the user to pick between options inline.
- **Location sharing** — the user can share real-time location inbound; treat it as
  structured data, not text.
- **Contact cards** — send/receive a contact (name, number) as a card.
- **Profile identity** — the bot's display name + avatar, synced to the user.
- **Group chats** — create/manage groups (name, avatar, participants); messages
  carry which group/sender they came from.
- **Generative mini-apps** — interactive cards delivered inside the conversation
  (e.g. a flight-status card) for live, app-like experiences.

## Etiquette & limits (important)

- **Conversational, not spammy.** Photon/Apple flag lines that broadcast or send
  repeated unanswered messages. For a personal assistant texting its own user this
  is low-risk, but: don't send bursts, don't pile on follow-ups the user hasn't
  answered, and keep the tone human.
- **Caps:** ~5,000 messages/server/day and ~50 *new* conversations/line/day (replies
  in an existing thread don't count). Plenty for normal use; just don't loop sends.
- **Inbound-first is best** — a thread the user started never shows Apple's
  "Report Junk" banner. Proactive first-contact is fine for your own number but
  shouldn't be noisy.
- **Delivery is at-least-once** — Jarvis dedupes inbound for you.

## If something fails

A send error usually means the sidecar is down or credentials are missing/expired.
Don't silently swallow it — tell the user it didn't go through and point them at the
Photon setup screen. Don't claim a message was delivered unless the send succeeded.

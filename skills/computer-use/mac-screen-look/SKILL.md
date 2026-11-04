---
name: mac-screen-look
description: "Read Pranav's Mac screen, answer, and send him the shot."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [mac, screenshot, screen, vision, computer-use]
    related_skills: [mac-control, web-task-router]
---

# Mac Screen Look Skill

For when Pranav asks about what's on his Mac's screen ("what's on my screen",
"is this a good deal", "what does this error mean", "send me a ss of my Mac").
It captures the right thing, answers the actual question, and puts the picture
in the chat when he wants to see it. It never clicks or types.

## When to Use

- "Send me a screenshot / ss / pic of my Mac (screen)".
- "What's on my screen", "look at this", "is this a good price", "what does this
  error say", "read me what's open in Brave".
- After Mac work, when he wants to see the result.

Not for: doing something on the screen (`mac-control`); web pages you can open
yourself on the server (`web-task-router`). Reading the page there is cleaner
than a screenshot.

## Prerequisites

- Mac online; pass the Mac's exact name as `device`.
- Load in one go: `tool_search` `select:device_screenshot,device_current_window,device_ui_look`.

## How to Run

1. Whole screen: `device_screenshot {device}`; region: add `region {x,y,w,h}`.
2. One app's window, readable even behind other windows or on another Space:
   `device_ui_look {app: "<App>", device}`. It returns a screenshot plus the
   window's text and elements.
3. Every image result carries `show_with`. Put that exact line in your reply, on
   its own line, to show him the picture. Never write your own `MEDIA:` or
   `![]()` line.

## Quick Reference

| He says | Do |
|---|---|
| "send me a ss of my mac" | `device_screenshot` → reply with one caption line + the `show_with` line |
| "what's on my screen" | `device_screenshot` → 2–3 line summary of what's in front; offer the picture |
| "is this a good deal" | `device_current_window` → if it's a web page, read the URL/title, check the price on the web (`web-task-router`), answer with the comparison, include the shot |
| "what does this error mean" | `device_screenshot` (or `device_ui_look` on the app) → quote the error text exactly → explain + fix |
| "what's open in <App>" | `device_ui_look {app}` → answer from its text |

## Procedure

1. Decide whether he wants the **picture**, an **answer**, or both. "Send / show
   me" means picture. A question means answer, and include the picture when it
   helps.
2. Capture once. If the shot shows only the wallpaper, a black frame or the lock
   screen:
   - check the lock with `device_run_shell {cmd: "ioreg -n Root -d1 | grep -c CGSSessionScreenIsLocked"}`;
     if locked, tell him it's locked and offer Unlock Mac from the iPhone;
   - otherwise the app is on another Space, so use `device_ui_look {app}` for that app.
3. Read before you claim. Quote prices, names and errors exactly as on screen. If
   text is too small or cut off, zoom with `region` or `device_ui_look` instead
   of guessing.
4. For judgment calls ("good deal?"), compare against the web, not your memory.
   Name the source and price you compared with.
5. Reply: the answer first, then the `show_with` line if he asked to see it.

## Pitfalls

- Never open the Screenshot app, press cmd+shift+4, or save files to his Desktop
  for a screenshot. `device_screenshot` already makes one.
- Don't read the clipboard to get text off the screen.
- Screenshots reach you, not him, unless the reply carries `show_with`. "The
  screenshots return inline rather than as files" is wrong; use `show_with`.
- If he's looking at something private (messages, banking), describe only what he
  asked about.
- One capture per question. Don't loop screenshots waiting for a change; use
  `device_wait_for_image` only for a known image.

## Verification

- His question is answered with text read from the capture (quoted where exact).
- When he asked to see it, the reply contains the tool's `show_with` line.

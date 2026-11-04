---
name: web-forms-logins
description: "Log into sites, fill forms, upload files, hand off 2FA."
version: 1.0.0
author: Pranav Krishna, JarvisCopilot
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [browser, forms, login, upload, 2fa, captcha, job-application, computer-use]
    related_skills: [web-task-router, mac-control, bitwarden]
---

# Web Forms & Logins Skill

For sign-ins, applications and other forms on the web: job applications,
account settings, bookings, sign-ups, anything behind a login. It picks the
place where he's already signed in, fills fields in batches, gets files into
upload fields without fighting the native file picker, and hands captchas, 2FA
and passwords to him instead of looping. It never invents his personal details.

## When to Use

- "Apply to this job", "fill out this form", "sign me up for…", "log in to
  <site> and check…", "change my <setting> on <site>".
- Any web task that needs his account, his files (resume, ID), or a submit button.

## Prerequisites

- Where it runs, in order of preference:
  1. **His Mac** (he's usually already signed in): `computer_do` in his browser,
     `app: "Google Chrome"` or `"Brave Browser"`. Use `chrome_*` only when
     `computer_do` stalls.
  2. **Cloud browser** (live view he can watch and take over): start with
     `browser_navigate`. Interactive steps (`browser_type`, `browser_click`)
     move the task to the cloud browser. The first interactive call after the
     move is **not performed**, so repeat it.
  3. Server headless browser alone: only public forms with no login.
- His details come from memory (`memory_recall`: name, email, phone, address,
  school, work history) or the documents he gave you. Never make up an answer to
  a form question.

## How to Run

1. **Recon the form first** (one call): `browser_extract {url, instruction: "list every
   field: label, type, required, options; list file uploads; list the submit button"}`,
   or `device_ui_look` on the Mac page. Now you know all the questions.
2. **Collect answers in one batch.** Fill what memory and his documents cover. For
   the rest, ask him ONE `form_ask` with all missing fields together. Required
   legal or attestation questions (work authorization, sponsorship, demographics,
   "I certify…") always go to him.
3. **Fill in batches**, not one call per field:
   - Mac: one `computer_do` with `steps` listing each field and its exact `text`.
   - Cloud/headless: `browser_run` with `fill` steps, then `wait_for`.
4. **Uploads** (see Procedure).
5. **Review before submit.** Read the filled page back
   (`browser_extract "every field's current value"` or `device_ui_look`). Show him a
   short summary, then submit only after his yes. Submitting an application or
   payment counts as sending.
6. **Confirm submission** from the page that follows ("Application received",
   a confirmation number). Quote it.

## Quick Reference

| Blocker | Do |
|---|---|
| Login wall, he's signed in on the Mac | do it on the Mac (`computer_do`) |
| Login wall, cloud browser | ask him to tap **Take over** on the browser card and sign in; continue after he says done |
| Password needed | never ask for it in chat. He signs in himself (Take over / his Mac), or use the `bitwarden` skill if its vault is unlocked |
| Captcha / "press and hold" / Cloudflare check | stop, ask him to Take over or solve it on the Mac; never try to solve it |
| 2FA code | ask him for the code (or he enters it via Take over) |
| Native file picker (Mac) | see Uploads below |
| JS alert/confirm on Mac Chrome | `computer_do` press the button by name; don't change Chrome settings |
| Page "Target closed" / extension errors (chrome_*) | switch to `computer_do` in the same browser |

## Procedure

**Uploads (resume, ID, photo):**
1. The file must be on the Mac. Find it with
   `device_run_shell {cmd: "mdfind -name '<Resume>' | grep -iE '\\.(pdf|docx)$' | head"}`.
   If several match, ask which one (show names and dates).
2. On the Mac, click the upload button with `computer_do`. In the macOS file
   picker, use these steps, each as its own `computer_do` step:
   - `do: "press cmd+shift+g"`
   - `do: "type the path", text: "<full path>"`
   - `do: "press return"`
   - `do: "click Open"`
3. Verify the page shows the file name next to the field.
4. A file only in the chat or on the server has to reach the Mac first. Ask him
   to AirDrop or save it, or download it on the Mac:
   `device_run_shell {cmd: "curl -L -o ~/Downloads/<name> '<url>'"}`.
   Then upload it.

**Long multi-page forms:** after each page, read it back, then continue. If a step
fails twice, stop and tell him the page and the field. Never loop back to the start
silently.

## Pitfalls

- Toggling browser settings ("Allow JavaScript from Apple Events") or installing
  anything to get around a dialog: don't.
- One call per field burned 96 tool calls on one application. Batch the fills.
- Never type his passwords, card numbers or SSN from memory or chat history.
  Payment and identity fields are his to enter.
- Don't submit, pay or send without his yes in this turn.
- Don't retry the same failing click or type. Re-read the page, then use another
  route (Mac ↔ cloud) or ask him.

## Verification

- Every field was read back before submit, and he approved.
- After submit, the reply quotes the confirmation text or number from the page.
- Uploaded files show their names on the form.

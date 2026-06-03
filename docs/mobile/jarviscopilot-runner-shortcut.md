# Phone-control Shortcuts — build + install

JARVIS changes **iOS-locked settings** (brightness, volume, Wi-Fi, Bluetooth, Focus) and
opens URLs through a small set of **per-verb Shortcuts**. This doc covers why it's per-verb,
how they're generated/signed, and how to install them.

## The iOS reality

Since **iOS 15**, the Shortcuts app refuses to import any Shortcut that isn't **digitally
signed by Apple** — there's no "Allow Untrusted Shortcuts" toggle, and a raw `.shortcut`
file fails with *"Importing unsigned shortcut files is not supported."*

You do **not** need the editor or an iCloud link. On a Mac, the `shortcuts` CLI signs a
generated plist locally:

```
shortcuts sign --mode people-who-know-me --input X.unsigned.shortcut --output "JC Foo.shortcut"
```

The signed file imports in one tap (AirDrop → **Add Shortcut**). The shortcut **name comes
from the filename**, so it must match `verbShortcutNames` in
`mobile_client/lib/skills/phone_command.dart`.

## Why per-verb, not one JSON dispatcher (hard-won)

A single "JarvisCopilot Runner" that parsed a JSON command and branched on the verb was
built and tested exhaustively on-device. It does **not** work, because two iOS Shortcuts
primitives are unreliable for this:

- **`Get Dictionary from Input`** returns an **empty dictionary** for a multi-key JSON
  payload delivered via x-callback `input=text`. (A single-key payload sometimes parsed; the
  two-key `{"action":…,"value":…}` consistently came back empty — verified by showing the
  parsed dict on screen: `dict=[]` with the raw input intact.)
- the **`If`** action would **not branch** on the verb string, even when fed a clean value
  from `Split Text` (so a list-based single shortcut failed too).

What *is* rock-solid (each verified on-device): x-callback text **input delivery**, **`Get
Numbers from Input`**, and the **`Set …` actions fed a real number**. So each verb is its
own Shortcut built from only those:

```
raw text input  ->  Get Numbers from Input  ->  the one action
```

No dictionary, no key lookup, no conditional, no value coercion. (Coercing the value to
`WFStringContentItem` was an earlier red herring — it turns the number into a string and
`Set Brightness` silently ignores it. A *number* is required.)

## The verbs / Shortcuts

| Verb (phone_control `action`) | Shortcut name | Raw input the app sends | Action |
|---|---|---|---|
| `brightness` | `JC Brightness` | `0.0`–`1.0` (e.g. `0.3`) | Set Brightness |
| `volume`     | `JC Volume`     | `0.0`–`1.0`             | Set Volume |
| `wifi`       | `JC WiFi`       | `1` / `0`               | Set Wi-Fi |
| `bluetooth`  | `JC Bluetooth`  | `1` / `0`               | Set Bluetooth |
| `focus`      | `JC Focus`      | `1` / `0`               | Set Do Not Disturb |
| `open_url`   | `JC Open URL`   | a URL (e.g. `spotify://`) | Open URLs |

Everything else stays **native, zero-setup**: `battery_level`, `get_location`,
`clipboard_read/write`, `flashlight_on/off`, `vibrate`, `notify`, `text_to_speech`,
`make_call`, `send_sms`, `open_app`, `set_alarm`. `phone_control` refuses those and points
JARVIS at the native skill (`nativeRedirectSkill`).

## Regenerate + sign (macOS)

```
python3 tools/gen_phone_shortcuts.py          # -> /tmp/jcskills/*.unsigned.shortcut
for f in /tmp/jcskills/*.unsigned.shortcut; do
  name="$(basename "${f%.unsigned.shortcut}")"
  plutil -convert binary1 "$f"
  shortcuts sign --mode people-who-know-me --input "$f" \
    --output "$HOME/Downloads/${name}.shortcut"
done
```

## Install

AirDrop the six `~/Downloads/JC *.shortcut` files to the phone and tap **Add Shortcut** for
each. (To open an app, JARVIS uses `open_url` with the app's URL scheme, e.g. `spotify://`.)

## Test (through JARVIS)

- "set my brightness to 30%" → `phone_control({action:"brightness",value:0.3})` → `JC Brightness` input `0.3`
- "turn off wifi" → `phone_control({action:"wifi",value:0})` → `JC WiFi` input `0`
- "open spotify" → `phone_control({action:"open_url",url:"spotify://"})` → `JC Open URL`

Each run briefly flashes through the Shortcuts app (unavoidable on iOS) and applies the
setting immediately. `phone_control` passes an `x-success` callback
(`jarviscopilot://shortcut-result/<rid>`) so iOS **returns to JarvisCopilot** as soon as the
shortcut finishes — the verbs emit no output, so the result is empty, but the round-trip is
what brings the app back to the foreground (the earlier "hang" was the broken dispatcher
never completing, not the await).

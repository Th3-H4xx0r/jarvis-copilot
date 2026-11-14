# Power integrations

Built-in Jarvis features that live on the Integrations tab with a **Power** tag, an
on/off switch and a settings form — on the iPhone, the web and the Mac. They're
written into the code (server and devices), so they can do far more than a regular
integration: own HTTP routes, background services, agent tools, plugin hooks and
native device code. They can't be created from the chat setup flow.

Today's Power integrations: `imessage-memory`, `jarvis-health`, `car`, `door-alarm`,
`dashcam`, `vault`, `widgets`, `kanban`, `security-advisor`, `island-designs`, `photon`.

## Power or regular?

| Make a regular integration when… | Make a Power integration when… |
|---|---|
| Jarvis can build it from chat: registry data, schedules, skills, a JSON card. | It needs code: server routes, a background service, agent tools, hooks, device code. |
| It's yours to create, edit and delete from the app. | It ships with Jarvis and should only ever be switched off, never deleted. |

## Anatomy

```
jarvis_power/
  base.py          PowerIntegration, Setting, Link, PowerError
  discovery.py     finds integrations/<dir>/ packages; validate()
  state.py         on/off + settings in the integration's registry space (doc "power")
  switch.py        the one path every change takes (app, web, Mac, Jarvis)
  approvals.py     Face ID approvals (domain jarvis-power)
  manager.py       starts/stops background work per process (webui, gateway)
  gate.py          route 409s, tool refusals, cache-safe per-chat toolsets, skills, hooks
  api.py           /api/power rows, cards, card/page UI
  surfaces.py      CATALOG of device places that hide while an integration is off
  stores.py        helpers to keep settings where a feature already keeps them
  integrations/
    _template/     copy me (never loaded: leading underscore)
    <dir>/__init__.py + ui.json
webui/api/power_routes.py                      /api/power + the route gate
tools/power_tool.py                            power_list / power_set (Jarvis)
ios_app/JarvisCopilot/Copilot/More/Integrations/Power/   PowerState, PowerViews, PowerGates, PowerNative, approvals
ios_app/JarvisCopilot/Copilot/Shared/PowerShared.swift   off ids in the App Group (extensions, CarPlay)
webui/static/power.js, integration_ui.js       web Power section + JSON renderer
mac_app/Sources/JarvisVoiceUI/Mac/MacPowerPane.swift     native Mac Power section
```

## The manifest

One `PowerIntegration` subclass per package. Only the four identity strings are required.

| Attribute / method | Meaning |
|---|---|
| `id`, `name`, `icon`, `summary` | `id` is permanent: the registry space id and what devices check. `name` must be a plain name (letters, digits, space, `_ . & -`). `icon` is an SF Symbol name. |
| `default_enabled` / `seed_enabled()` | State the first time the framework sees it. Override `seed_enabled()` to mirror today's reality (an old enable flag). Seeded once, never again. |
| `protected` | Switching off (from any device or by Jarvis) needs Face ID on the iPhone. |
| `can_switch_off()` | A reason it can't be switched off right now, shown as-is (the door alarm: "Disarm the alarm first"). |
| `processes` | Where `start()`/`stop()` run: `"webui"`, `"gateway"`. |
| `start(process)` / `stop(process)` | Begin / end **all** background work in that process. Off must really mean off. |
| `toolsets` | Its agent toolsets. While off: calls refused at once, left out of **new** chats. |
| `route_prefixes` / `route_exempt` | Webui paths it owns (409 while off) and paths under them that stay open. |
| `surfaces` | Device places hidden while off — each id must be in `surfaces.CATALOG`. |
| `links` | `Link(platform, target, label)`: existing screens its page offers to open. |
| `native` | `{"ios": {"card"}, …}`: pieces drawn natively instead of from `ui.json`. |
| `settings` | `Setting(key, label, kind, default, help, options, min, max, unit, jarvis)`; kinds `toggle text number picker secret`; `jarvis` = `allow` / `ask` (Face ID) / `never` (app only). |
| `read_settings()` / `write_settings(changes)` | Default: kept in the power doc. Override to use the feature's own store (config.yaml, .env, its database — see `stores.py`). Secrets are write-only over the API. |
| `actions`, `state()`, `action(name, event)` | Its JSON card/page: `state()` is what `ui.json` binds to; controls run `action()`. Same result shape as a UI script: `{state?, toast?, error?}`. |
| `status_line()` | The one line under its name on the card (time-boxed to 1 s). |
| `hooks()` | Plugin hooks (`pre_llm_call`, …); they only fire while it's on. For an existing plugin, wrap its own hooks with `jarvis_power.gate.gated(id, fn)`. |
| `adopt_space` | Reuse an existing registry space with this id (Jarvis Health). Otherwise a collision with a user's space gets `power-<id>`. |

`ui.json` is `{"presentations": {"card": …, "page": …}}` in the same element set as
regular integration UIs (see the `integration-ui` skill: sections take `title`, stats
take `caption`). It's validated with `jarvis_registry.ui.validate_ui`, and every
control's `action` must be listed in `actions`.

## Lifecycle

1. **Seed** — the webui's boot calls `state.ensure_all()`: each integration gets its
   registry space and, the first time only, its power doc from `seed_enabled()`.
   Before that (a gateway that booted first), a process uses `seed_enabled()` too.
2. **Switch** — `switch.request_enabled(id, enabled, by)`: refuses with
   `can_switch_off()`'s reason; protected → Face ID approval; otherwise
   `apply_enabled()` writes the doc, pauses/restores its schedules (only those it
   paused) and reconciles this process.
3. **Manager** — the webui and the gateway each run `manager_for(process)`; a
   thread polls `state.version()` every 3 s and calls `start`/`stop` for what
   changed. Failures are recorded on the row (`error`) and retried.
4. **Gates** — routes answer 409 `{"error": "<Name> is switched off", "power_off": id}`;
   tool calls return `"<Name> is switched off"`; hooks no-op; skills hide.
5. **Prompt cache** — a chat's off toolsets are fixed the first time it builds
   (`gate.session_off_toolsets`), so a switch never changes an open chat's tools or
   system prompt. Switching on gives Jarvis the tools from the next chat.
6. **Devices** — the webui publishes bridge topic `power` on every change; phones
   refresh `/api/power`.

## Protected integrations and Jarvis

Jarvis has `power_list` and `power_set` (toolset `power`, over the host-signed
loopback so the server knows it's Jarvis). It may do anything except: switching a
**protected** one off, or changing a setting marked `ask`, becomes a Face ID approval
on the iPhone (`/api/power/approvals`, signed `jarvis-power|<command>|<approval id>|<ts>`
with the shared approver in `plugins/toyota/approver.py`); a setting marked `never`
is refused. Web and Mac switch-offs of protected integrations go to the phone too.

**Never gate shared infrastructure.** The Face ID approver's routes live under
`/api/car` but serve the door alarm, vault, security advisor and Power approvals —
they're `route_exempt` on the Car, and every feature's `/approvals` route stays open
so a waiting approval can still be answered.

## Devices

Every place that belongs to an integration checks its switch. Unknown or unreachable
state counts as **on** — never hide a feature because a fetch failed.

| Platform | How |
|---|---|
| iPhone app | `PowerState.shared.isOn(id)`, `.powerGated(id)`, `PowerGates.whenOn(id) { start… }` for services. |
| Widget / Live Activity extensions, CarPlay | `PowerShared.isOn(id)` (App Group cache of the off ids). |
| Web | `JCPower.isOn(id)`; mark elements `data-power="<id>"` and they hide while off. |
| Mac | `MacIntegrationsPane` (native Power section); the tray's iMessage uploader follows `/api/imessage-memory/config`. |

Add each new place to `jarvis_power/surfaces.py` with where it lives.

**Native escape hatch:** iPhone — add a `case` to `PowerNative.card/page/settings`;
web — `JCPower.native[id] = {card(el,row), page(el,row), settings(el,row)}`; then
list the piece in the manifest's `native`. A platform without it falls back to JSON.

## Adding one — checklist

1. Copy `jarvis_power/integrations/_template/` to `jarvis_power/integrations/<dir>/`,
   set `id`/`name`/`icon`/`summary`. Keep top-level imports light (lazy-import
   feature modules inside methods: the tool gate imports every integration).
2. Declare `processes`, `toolsets`, `route_prefixes`/`route_exempt`, `settings`.
   Write `start()`/`stop()` so off stops everything; `seed_enabled()` if the feature
   already has an on/off flag (that flag becomes this switch — never two switches).
3. Write `ui.json` + `state()`/`action()` (or set `native`).
4. Add its `surfaces` to `surfaces.CATALOG`; gate those places on every device.
5. Tests in `tests/jarvis_power/integrations/test_<dir>.py`: off stops its work, on
   restarts it, seed matches today.
   `tests/jarvis_power/test_discovery.py::test_every_real_integration_validates`
   checks the manifest for you.
6. Ship: deploy the server, iPhone via `release.sh`, Mac via `mac_app/build.sh`
   (commit the dylib) + `build-app.sh` + `publish-app-update.sh`.

## Pitfalls

- **Two switches.** If a feature had its own enabled flag, make the Power switch that
  flag (iMessage memory) or turn the old flag into a setting with its own meaning
  (Jarvis Health's "Analysis & alerts").
- **Changing an open chat's tools.** Never add or remove tools mid-chat; the gate
  already handles it.
- **Cross-process state.** The webui and gateway are different processes; anything
  the gateway owns (Kanban dispatcher, Photon adapter) must react to the switch.
- **Phone services without a stop.** `PowerGates.whenOn` starts a service the first
  time its integration is on; one that can't stop cleanly stops at the next launch
  (the server refuses its calls meanwhile). Give new services a real `stop()`.
- **Profiles.** Use `get_hermes_home()` for any file; the registry is per profile.
- **Seeding is forever.** Get `seed_enabled()` right before the first deploy.

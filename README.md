# Jarvis Copilot

A voice-first AI assistant fork of [JarvisCopilot](https://github.com/NousResearch/jarviscopilot) with a browser-based web UI ported from [nesquena/jarviscopilot-webui](https://github.com/nesquena/jarviscopilot-webui), tool-enabled voice chat with an ack → tool → confirm cadence, a JARVIS personality with a matching Piper neural voice, Fish Audio TTS support, and a self-signed-TLS launcher so the voice tab works over your LAN out of the box.

Everything JarvisCopilot does — skills, cron jobs, memory, sessions, the full tool ecosystem, the messaging gateway — still works. This fork adds a voice-tab UI on top.

---

## One-line install

### Linux / macOS / WSL2

```bash
curl -fsSL https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/install-jarviscopilot.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/install-jarviscopilot.ps1 | iex
```

The installer:

1. Clones this fork into `~/JarvisCopilot` (configurable via `$JARVISCOPILOT_DIR`)
2. Creates `.venv/` and installs JarvisCopilot core + voice extras (`faster-whisper`, `edge-tts`, `piper-tts`) + webui dependencies
3. Generates a self-signed TLS cert at `~/.jarviscopilot/webui-tls/` so HTTPS works without buying a real cert
4. Prints next steps: Codex auth + first launch

**Re-runs are idempotent.** Running it again `git pull --ff-only`s the code and refreshes `pip` only — it never touches your `~/.jarviscopilot/` config, skills, cron jobs, sessions, or credentials.

---

## After install

```bash
# 1. One-time: log in with your ChatGPT account (device-code flow)
~/JarvisCopilot/.venv/bin/jarviscopilot auth add openai-codex --type oauth --no-browser

# 2. One-time: pick the model
~/JarvisCopilot/.venv/bin/jarviscopilot model openai-codex

# 3. Launch the web UI (binds 0.0.0.0:8787, TLS)
~/JarvisCopilot/scripts/launch-webui.sh        # Linux/macOS
~/JarvisCopilot/scripts/launch-webui.ps1       # Windows PowerShell
```

Then open **https://localhost:8787** on the host, or **https://&lt;your-LAN-ip&gt;:8787** from any other device on your network. The first visit shows a "Not Private" warning because the cert is self-signed — tap *Advanced → Proceed* once and the mic/voice features work.

---

## What's added on top of JarvisCopilot

| Surface | Added by Jarvis Copilot |
| --- | --- |
| **Web UI** | Vendored from [nesquena/jarviscopilot-webui](https://github.com/nesquena/jarviscopilot-webui) — three-panel chat, workspace browser, sessions, kanban, skills, memory. Now with a Voice tab. |
| **Voice tab** | Push-to-talk + Realtime WebSocket modes. Web Audio mic capture, browser-side interim transcript via Web Speech API, server-side STT via JarvisCopilot's `faster-whisper`. Streams responses as they arrive (text speaks while the next tool runs). |
| **Particle-sphere orb** | Pure Canvas2D port of JarvisClaw's `VoiceWaveform` — rotating chrome rings, additive blending, amplitude-driven spike rim, state-driven color (idle blue, listening cool, thinking pulsing purple, speaking warm orange). |
| **Voice → chat agent** | Voice transcripts route through the user's active chat session so the agent's full tool kit (terminal, browser, file, web, etc.) is available. Auto-approve via `tools.approval.enable_session_yolo()` — speaking is consent. |
| **Ack → tool → confirm** | SOUL.md prompt nudges the model to narrate before each tool ("Opening Chrome…") and confirm after ("Chrome is open."). Each text segment is TTS'd inline and played as it lands. |
| **JARVIS personality** | Settings → Conversation → Personality: pick *jarvis-mcu* and the assistant speaks as Tony Stark's British butler. Auto-swaps the TTS engine to Piper using the `jgkawell/jarvis` neural voice model (downloaded from HuggingFace on first pick, ~114 MB, cached locally). |
| **Voice engine picker** | In-app dropdown for `edge`, `openai`, `elevenlabs`, `gemini`, `piper`, and `fish-audio`. Settings → Voice Providers shows per-engine API key + voice ID config with status badges. |
| **Fish Audio support** | Cloud TTS via `api.fish.audio/v1/tts` with tolerant URL-style voice-ID parsing (`fish.audio/m/<id>?version=s2-pro` works inline). Bearer-auth, model override via `?version=`, 24 kHz WAV decoded by the browser. |
| **TLS by default** | `webui/api/tls.py` generates a self-signed cert with SANs for `localhost`, `127.0.0.1`, and every local IPv4 interface (LAN, Hyper-V, Tailscale). Required so browsers grant `getUserMedia` permission outside `localhost`. |
| **One-line installers** | `scripts/install-jarviscopilot.{sh,ps1}` for first-time setup; `scripts/launch-webui.{sh,ps1}` for every run. Idempotent — re-runs update code without touching your data. |

---

## Configuration

All settings live under `~/.jarviscopilot/` and are unchanged from upstream JarvisCopilot:

- `~/.jarviscopilot/config.yaml` — model provider, personalities, TTS engine + voice, cron settings
- `~/.jarviscopilot/SOUL.md` — assistant identity / system prompt
- `~/.jarviscopilot/skills/` — your agent-created skills
- `~/.jarviscopilot/auth.json` — pooled credentials (OAuth tokens, API keys)

The installer **never overwrites these** — re-run it as often as you like.

### Cron job formatting

By default JarvisCopilot wraps cron job replies in a header/footer (job name, ID, stop instructions). To get just the content:

```yaml
cron:
  wrap_response: false
```

### Voice provider config

Set in `~/.jarviscopilot/config.yaml` (or via Settings → Voice Providers in the UI):

```yaml
tts:
  provider: fish-audio        # or: edge | openai | elevenlabs | gemini | piper
  fish-audio:
    api_key: <your-fish-key>  # or set FISH_AUDIO_API_KEY env var
    voice_id: <paste-from-fish.audio/m/...>
    model: s2-pro             # optional override
  piper:
    voice: ~/.jarviscopilot/cache/piper-voices/jarvis-high.onnx
    length_scale: 1.04
    noise_scale: 0.45
    noise_w_scale: 0.55
```

---

## What's `jarviscopilot` vs `jarviscopilot`?

Both commands exist and do the same thing — `jarviscopilot` is the primary name for this fork; `jarviscopilot` is kept as an alias for backward compatibility with the upstream docs and any external scripts that hardcode it.

```bash
jarviscopilot setup         # equivalent to: jarviscopilot setup
jarviscopilot auth list     # equivalent to: jarviscopilot auth list
```

State directory is still `~/.jarviscopilot/` — renaming the on-disk path would break every existing install and skill.

---

## Credits

- [JarvisCopilot](https://github.com/NousResearch/jarviscopilot) by [Nous Research](https://nousresearch.com) — the agent core, tool system, memory, cron scheduler, gateway, every part of the brains
- [jarviscopilot-webui](https://github.com/nesquena/jarviscopilot-webui) by [nesquena](https://github.com/nesquena) — the three-panel web UI vendored in `webui/`
- [JarvisClaw](https://github.com/jarvisclaw/jarvisclaw) — design inspiration for the voice tab, JARVIS persona, Piper voice config, and Fish Audio integration

---

## License

MIT — same as upstream JarvisCopilot. See [LICENSE](LICENSE).

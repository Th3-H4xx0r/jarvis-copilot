---
sidebar_position: 11
title: "ACP Editor Integration"
description: "Use JarvisCopilot inside ACP-compatible editors such as VS Code, Zed, and JetBrains"
---

# ACP Editor Integration

JarvisCopilot can run as an ACP server, letting ACP-compatible editors talk to JarvisCopilot over stdio and render:

- chat messages
- tool activity
- file diffs
- terminal commands
- approval prompts
- streamed thinking / response chunks

ACP is a good fit when you want JarvisCopilot to behave like an editor-native coding agent instead of a standalone CLI or messaging bot.

## What JarvisCopilot exposes in ACP mode

JarvisCopilot runs with a curated `jarviscopilot-acp` toolset designed for editor workflows. It includes:

- file tools: `read_file`, `write_file`, `patch`, `search_files`
- terminal tools: `terminal`, `process`
- web/browser tools
- memory, todo, session search
- skills
- execute_code and delegate_task
- vision

It intentionally excludes things that do not fit typical editor UX, such as messaging delivery and cronjob management.

## Installation

Install JarvisCopilot normally, then add the ACP extra:

```bash
pip install -e '.[acp]'
```

This installs the `agent-client-protocol` dependency and enables:

- `jarviscopilot acp`
- `jarviscopilot-acp`
- `python -m acp_adapter`

For Zed registry installs, Zed launches JarvisCopilot through the official ACP Registry entry. That entry uses a `uvx` distribution that runs:

```bash
uvx --from 'hermes-agent[acp]==<version>' jarviscopilot-acp
```

Make sure `uv` is available on `PATH` before using the registry install path.

## Launching the ACP server

Any of the following starts JarvisCopilot in ACP mode:

```bash
jarviscopilot acp
```

```bash
jarviscopilot-acp
```

```bash
python -m acp_adapter
```

JarvisCopilot logs to stderr so stdout remains reserved for ACP JSON-RPC traffic.

For non-interactive checks:

```bash
jarviscopilot acp --version
jarviscopilot acp --check
```

### Browser tools (optional)

Browser tools (`browser_navigate`, `browser_click`, etc.) depend on the
`agent-browser` npm package and Chromium, which aren't part of the Python
wheel. Install them with:

```bash
jarviscopilot acp --setup-browser           # interactive (prompts before ~400 MB download)
jarviscopilot acp --setup-browser --yes     # accept the download non-interactively
```

This is the standalone command. The Zed registry's terminal-auth flow (`jarviscopilot acp --setup`) also offers the browser bootstrap as a follow-up question after model selection, so most users never need to run `--setup-browser` directly.

What it does:

- Installs Node.js 22 LTS into `~/.jarviscopilot/node/` if missing
- `npm install -g agent-browser @askjo/camofox-browser` into that prefix (no sudo needed — `npm`'s `--prefix` points at the user-writable Hermes-managed Node)
- Installs Playwright Chromium, or uses a detected system Chrome/Chromium when available

The bootstrap is idempotent — re-running it is fast and skips work that's already done.

## Editor setup

### VS Code

Install the [ACP Client](https://marketplace.visualstudio.com/items?itemName=formulahendry.acp-client) extension.

To connect:

1. Open the ACP Client panel from the Activity Bar.
2. Select **JarvisCopilot** from the built-in agent list.
3. Connect and start chatting.

If you want to define JarvisCopilot manually, add it through VS Code settings under `acp.agents`:

```json
{
  "acp.agents": {
    "JarvisCopilot": {
      "command": "jarviscopilot",
      "args": ["acp"]
    }
  }
}
```

### Zed

Zed v0.221.x and newer installs external agents through the official ACP Registry.

1. Open the Agent Panel.
2. Click **Add Agent**, or run the `zed: acp registry` command.
3. Search for **JarvisCopilot**.
4. Install it and start a new JarvisCopilot external-agent thread.

Prerequisites:

- Configure JarvisCopilot provider credentials first with `jarviscopilot model`, or set them in `~/.jarviscopilot/.env` / `~/.jarviscopilot/config.yaml`.
- Install `uv` so the registry launcher can run `uvx --from 'hermes-agent[acp]==<version>' jarviscopilot-acp`.

For local development before the registry entry is available, use a custom agent server in Zed settings:

```json
{
  "agent_servers": {
    "hermes-agent": {
      "type": "custom",
      "command": "jarviscopilot",
      "args": ["acp"]
    }
  }
}
```

### JetBrains

Use an ACP-compatible plugin and point it at:

```text
/path/to/hermes-agent/acp_registry
```

## Registry manifest

The source copy of JarvisCopilot' official ACP Registry metadata lives at:

```text
acp_registry/agent.json
acp_registry/icon.svg
```

The upstream registry PR copies those files into the top-level `hermes-agent/` directory in `agentclientprotocol/registry`.

The registry entry uses a `uvx` distribution that points directly at the `hermes-agent` PyPI release:

```text
uvx --from 'hermes-agent[acp]==<version>' jarviscopilot-acp
```

The registry CI verifies that the pinned version exists on PyPI, so the manifest's `version` and uvx `package` pin must always match `pyproject.toml`. `scripts/release.py` keeps them in lockstep automatically.

## Configuration and credentials

ACP mode uses the same JarvisCopilot configuration as the CLI:

- `~/.jarviscopilot/.env`
- `~/.jarviscopilot/config.yaml`
- `~/.jarviscopilot/skills/`
- `~/.jarviscopilot/state.db`

Provider resolution uses JarvisCopilot' normal runtime resolver, so ACP inherits the currently configured provider and credentials. JarvisCopilot also advertises a terminal auth method (`--setup`) for first-run registry clients; this opens JarvisCopilot' interactive model/provider setup.

## Session behavior

ACP sessions are tracked by the ACP adapter's in-memory session manager while the server is running.

Each session stores:

- session ID
- working directory
- selected model
- current conversation history
- cancel event

The underlying `AIAgent` still uses JarvisCopilot' normal persistence/logging paths, but ACP `list/load/resume/fork` are scoped to the currently running ACP server process.

## Working directory behavior

ACP sessions bind the editor's cwd to the JarvisCopilot task ID so file and terminal tools run relative to the editor workspace, not the server process cwd.

## Approvals

Dangerous terminal commands can be routed back to the editor as approval prompts. ACP approval options are simpler than the CLI flow:

- allow once
- allow always
- deny

On timeout or error, the approval bridge denies the request.

## Troubleshooting

### ACP agent does not appear in the editor

Check:

- In Zed, open the ACP Registry with `zed: acp registry` and search for **JarvisCopilot**.
- For manual/local development, verify the custom `agent_servers` command points to `jarviscopilot acp`.
- JarvisCopilot is installed and on your PATH.
- The ACP extra is installed (`pip install -e '.[acp]'`).
- `uv` is installed if launching from the official Zed registry entry.

### ACP starts but immediately errors

Try these checks:

```bash
jarviscopilot acp --version
jarviscopilot acp --check
jarviscopilot doctor
jarviscopilot status
```

### Missing credentials

ACP mode uses JarvisCopilot' existing provider setup. Configure credentials with:

```bash
jarviscopilot model
```

or by editing `~/.jarviscopilot/.env`. Registry clients can also trigger JarvisCopilot' terminal auth flow, which runs the same interactive provider/model setup.

### Zed registry launcher cannot find uv

Install `uv` from the official uv installation docs, then retry the JarvisCopilot thread from Zed.

## See also

- [ACP Internals](../../developer-guide/acp-internals.md)
- [Provider Runtime Resolution](../../developer-guide/provider-runtime.md)
- [Tools Runtime](../../developer-guide/tools-runtime.md)

# Jarvis Terminal Bridge

Lets Jarvis reach the terminals inside VS Code. Nothing outside VS Code can type
into its built-in terminal, so this extension connects each VS Code window to the
local Jarvis client (`jc-client`) and does three things on its behalf:

- types a message into the terminal running a given Claude Code / Codex session
- runs a command (for example `claude --resume <id>`) in a new "Jarvis" terminal
  of the window that has a given folder open
- shows (focuses) a terminal

It talks only to `~/.jarviscopilot-client/vscode.sock` on this machine. No network,
no npm packages, no build step: just `package.json` and `extension.js`.

## Install

`jc-client update` packs and installs it (`code --install-extension … --force`).
By hand, from `desktop_client/`:

```bash
python3 -c "from jc_client.vscode_pack import install_extension; print(install_extension())"
```

When you change `extension.js`, bump `version` in `package.json` so VS Code
treats the new build as an update.

## Protocol

Newline-delimited JSON over the UNIX socket. The extension reconnects with
backoff (1 s doubling to 30 s) while jc-client is not running.

Extension → jc-client, on connect and whenever a terminal opens or closes or
the workspace folders change:

```json
{"type":"hello","window":"<vscode.env.sessionId>","folders":["/abs/path"],
 "terminals":[{"id":0,"name":"zsh","pid":12345}]}
```

`pid` is the terminal's shell process id (`terminal.processId`).

jc-client → extension, each answered by exactly one
`{"type":"result","req":<same id>,"ok":true|false,"error"?:"…"}`:

| Request | Effect |
|---|---|
| `{"type":"send_text","req":1,"pid":12345,"text":"…"}` | bracketed-pastes the text into that terminal, then presses Return |
| `{"type":"run","req":2,"cwd":"/abs/path/sub","command":"…"}` | new terminal named "Jarvis" in `cwd`, shown, runs the command; `ok:false` "folder not open" when no workspace folder contains `cwd` |
| `{"type":"focus","req":3,"pid":12345}` | shows that terminal |

'use strict';
// Jarvis Terminal Bridge: connects this VS Code window to jc-client over
// ~/.jarviscopilot-client/vscode.sock so Jarvis can type into, run commands
// in, and focus this window's terminals. Newline-delimited JSON both ways;
// see README.md for the messages. Uses only the vscode API and Node's stdlib.

const vscode = require('vscode');
const net = require('net');
const os = require('os');
const path = require('path');
const fs = require('fs');

const SOCK_PATH = path.join(os.homedir(), '.jarviscopilot-client', 'vscode.sock');
const MIN_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30000;
const PID_TIMEOUT_MS = 2000;
const HELLO_DEBOUNCE_MS = 150;
// Claude Code and Codex read a paste and the Return that follows it as one
// chunk if they arrive together; a short gap makes the Return a real submit.
const ENTER_DELAY_MS = 150;
// A command for a new terminal waits for its shell (see runWhenSettled).
const SHELL_START_MS = 1500;
const SHELL_READY_MAX_MS = 10000;
const QUIET_MS = 1200;
const SETTLE_MAX_MS = 15000;

let sock = null;
let backoff = MIN_BACKOFF_MS;
let reconnectTimer = null;
let helloTimer = null;
let stopped = false;

function activate(context) {
  context.subscriptions.push(
    vscode.window.onDidOpenTerminal(scheduleHello),
    vscode.window.onDidCloseTerminal(scheduleHello),
    vscode.workspace.onDidChangeWorkspaceFolders(scheduleHello),
    { dispose: shutdown },
  );
  connect();
}

function deactivate() {
  shutdown();
}

function shutdown() {
  stopped = true;
  clearTimeout(reconnectTimer);
  clearTimeout(helloTimer);
  reconnectTimer = null;
  helloTimer = null;
  if (sock) {
    sock.destroy();
    sock = null;
  }
}

// ── connection ──────────────────────────────────────────────────────────
function connect() {
  reconnectTimer = null;
  if (stopped) return;
  const s = net.createConnection(SOCK_PATH);
  let buf = '';
  s.setEncoding('utf8');
  s.on('connect', () => {
    sock = s;
    backoff = MIN_BACKOFF_MS;
    sendHello();
  });
  s.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      onLine(line);
    }
  });
  s.on('error', () => { /* 'close' follows and schedules the retry */ });
  s.on('close', () => {
    if (sock === s) sock = null;
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  if (stopped || reconnectTimer) return;
  const delay = backoff;
  backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
  reconnectTimer = setTimeout(connect, delay);
}

function write(obj) {
  if (sock && !sock.destroyed) {
    sock.write(JSON.stringify(obj) + '\n');
  }
}

// ── hello: who this window is ───────────────────────────────────────────
function scheduleHello() {
  clearTimeout(helloTimer);
  helloTimer = setTimeout(() => {
    helloTimer = null;
    sendHello();
  }, HELLO_DEBOUNCE_MS);
}

async function sendHello() {
  if (!sock) return;
  try {
    const terms = vscode.window.terminals.slice();
    const pids = await Promise.all(terms.map(pidOf));
    write({
      type: 'hello',
      window: vscode.env.sessionId,
      folders: workspaceFolderPaths(),
      terminals: terms.map((t, i) => ({ id: i, name: t.name, pid: pids[i] })),
      submit: ['enter', 'now'],
      run: 'settled',   // a run waits for the new shell (runWhenSettled)
    });
  } catch (e) {
    console.error('[jarvis-terminal-bridge] hello failed', e);
  }
}

function workspaceFolderPaths() {
  return (vscode.workspace.workspaceFolders || [])
    .filter((f) => f.uri.scheme === 'file')
    .map((f) => f.uri.fsPath);
}

function pidOf(terminal) {
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PID_TIMEOUT_MS));
  const pid = Promise.resolve(terminal.processId).then(
    (p) => (typeof p === 'number' ? p : null),
    () => null,
  );
  return Promise.race([pid, timeout]);
}

async function terminalByPid(pid) {
  const want = Number(pid);
  const terms = vscode.window.terminals.slice();
  const pids = await Promise.all(terms.map(pidOf));
  const i = pids.findIndex((p) => p === want);
  return i >= 0 ? terms[i] : null;
}

// ── requests from jc-client ─────────────────────────────────────────────
function onLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    return;
  }
  if (!msg || typeof msg !== 'object' || msg.req === undefined) return;
  handle(msg).catch((e) => reply(msg.req, false, String((e && e.message) || e)));
}

async function handle(msg) {
  const req = msg.req;
  if (msg.type === 'send_text') {
    const t = await terminalByPid(msg.pid);
    if (!t) return reply(req, false, 'no terminal with that pid');
    t.sendText('\x1b[200~' + String(msg.text == null ? '' : msg.text) + '\x1b[201~', false);
    await sleep(ENTER_DELAY_MS);
    t.sendText(msg.submit === 'now' ? '\x1b[13;5u' : '\r', false);
    return reply(req, true);
  }
  if (msg.type === 'run') {
    const cwd = String(msg.cwd || '');
    if (!cwd || !folderContains(cwd)) return reply(req, false, 'folder not open');
    const t = vscode.window.createTerminal({ name: 'Jarvis', cwd });
    t.show(false);
    reply(req, true);
    return runWhenSettled(t, String(msg.command || ''));
  }
  if (msg.type === 'focus') {
    const t = await terminalByPid(msg.pid);
    if (!t) return reply(req, false, 'no terminal with that pid');
    t.show(false);
    return reply(req, true);
  }
  return reply(req, false, 'unknown request: ' + String(msg.type));
}

// A new terminal's shell is still starting, and the Python extension then
// clears the prompt (^C) and types its venv activation: a command typed at
// once is wiped. So wait for shell integration and for nothing to have run
// for a moment, then run it; without shell integration, give the shell a beat.
async function runWhenSettled(t, command) {
  const w = vscode.window;
  if (!w.onDidChangeTerminalShellIntegration || !w.onDidStartTerminalShellExecution) {
    await sleep(SHELL_START_MS);
    return t.sendText(command, true);
  }
  let running = 0;
  let lastActivity = Date.now();
  const subs = [
    w.onDidStartTerminalShellExecution((e) => {
      if (e.terminal === t) { running += 1; lastActivity = Date.now(); }
    }),
    w.onDidEndTerminalShellExecution((e) => {
      if (e.terminal === t) { running = Math.max(0, running - 1); lastActivity = Date.now(); }
    }),
  ];
  try {
    if (!t.shellIntegration) {
      await new Promise((resolve) => {
        const timer = setTimeout(done, SHELL_READY_MAX_MS);
        const sub = w.onDidChangeTerminalShellIntegration((e) => { if (e.terminal === t) done(); });
        function done() { clearTimeout(timer); sub.dispose(); resolve(); }
      });
      lastActivity = Date.now();
    }
    const deadline = Date.now() + SETTLE_MAX_MS;
    while (Date.now() < deadline && (running > 0 || Date.now() - lastActivity < QUIET_MS)) {
      await sleep(100);
    }
  } finally {
    subs.forEach((s) => s.dispose());
  }
  if (t.shellIntegration) return t.shellIntegration.executeCommand(command);
  return t.sendText(command, true);
}

function reply(req, ok, error) {
  const out = { type: 'result', req, ok: !!ok };
  if (error) out.error = error;
  write(out);
}

function folderContains(cwd) {
  const candidates = [cwd, realpath(cwd)];
  return workspaceFolderPaths().some((folder) =>
    [folder, realpath(folder)].some((f) => candidates.some((c) => isInside(f, c))));
}

function isInside(folder, p) {
  const rel = path.relative(folder, p);
  return rel === '' || (rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel));
}

function realpath(p) {
  try {
    return fs.realpathSync(p);
  } catch (e) {
    return p;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { activate, deactivate };

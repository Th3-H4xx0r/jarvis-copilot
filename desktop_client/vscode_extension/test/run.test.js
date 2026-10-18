'use strict';
// node --test desktop_client/vscode_extension/test/
// Drives the extension over its real socket with a stand-in for the vscode
// module: a "run" request opens a terminal, and the command must wait for the
// shell (and anything the Python extension types into it) before it goes in.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const Module = require('module');

function emitter() {
  const listeners = [];
  const event = (fn) => {
    listeners.push(fn);
    return { dispose() { listeners.splice(listeners.indexOf(fn), 1); } };
  };
  event.fire = (e) => listeners.slice().forEach((fn) => fn(e));
  return event;
}

function fakeVscode({ shellIntegrationApi }) {
  const log = [];
  const window = {
    terminals: [],
    onDidOpenTerminal: emitter(),
    onDidCloseTerminal: emitter(),
    createTerminal(opts) {
      const t = {
        name: opts.name,
        processId: Promise.resolve(4242),
        shellIntegration: undefined,
        show() {},
        sendText(text, addNewLine) { log.push(['sendText', text, addNewLine]); },
      };
      window.terminals.push(t);
      window.created = t;
      return t;
    },
  };
  if (shellIntegrationApi) {
    window.onDidChangeTerminalShellIntegration = emitter();
    window.onDidStartTerminalShellExecution = emitter();
    window.onDidEndTerminalShellExecution = emitter();
  }
  return {
    log,
    window,
    env: { sessionId: 'w1' },
    workspace: {
      workspaceFolders: [{ uri: { scheme: 'file', fsPath: '/proj' } }],
      onDidChangeWorkspaceFolders: emitter(),
    },
  };
}

// A fresh copy of the extension wired to `vscode`, talking to a socket under a
// temp HOME. Resolves with the extension, the server side of the connection,
// and the lines it has sent so far.
async function start(vscode) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'jtb-'));
  fs.mkdirSync(path.join(home, '.jarviscopilot-client'));
  const sockPath = path.join(home, '.jarviscopilot-client', 'vscode.sock');
  const lines = [];
  let conn;
  const connected = new Promise((resolve) => {
    const server = net.createServer((c) => {
      conn = c;
      let buf = '';
      c.setEncoding('utf8');
      c.on('data', (d) => {
        buf += d;
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          lines.push(JSON.parse(buf.slice(0, nl)));
          buf = buf.slice(nl + 1);
        }
      });
      resolve(server);
    });
    server.listen(sockPath);
  });
  const realHome = process.env.HOME;
  process.env.HOME = home;
  const extPath = require.resolve('../extension.js');
  delete require.cache[extPath];
  const load = Module._load;
  Module._load = function (request, ...rest) {
    return request === 'vscode' ? vscode : load.call(this, request, ...rest);
  };
  let ext;
  try {
    ext = require(extPath);
  } finally {
    Module._load = load;
    process.env.HOME = realHome;
  }
  ext.activate({ subscriptions: [] });
  const server = await connected;
  return {
    lines,
    send: (obj) => conn.write(JSON.stringify(obj) + '\n'),
    stop() { ext.deactivate(); server.close(); },
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(cond, ms = 5000) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error('timed out');
    await sleep(20);
  }
}

test('a run waits for the shell and its venv activation before typing', async () => {
  const vscode = fakeVscode({ shellIntegrationApi: true });
  const ext = await start(vscode);
  try {
    ext.send({ type: 'run', req: 1, cwd: '/proj', command: 'claude --resume abc' });
    await until(() => ext.lines.some((l) => l.type === 'result' && l.req === 1));
    assert.ok(ext.lines.find((l) => l.req === 1).ok, 'answers at once: the terminal is open');

    const t = vscode.window.created;
    await sleep(200);
    assert.deepStrictEqual(vscode.log, [], 'nothing typed before the shell is up');

    const ran = [];
    t.shellIntegration = { executeCommand: (cmd) => { ran.push(cmd); return {}; } };
    vscode.window.onDidChangeTerminalShellIntegration.fire({ terminal: t, shellIntegration: t.shellIntegration });
    // The Python extension activates the venv in the new shell.
    await sleep(100);
    const activation = {};
    vscode.window.onDidStartTerminalShellExecution.fire({ terminal: t, execution: activation });
    await sleep(1500);
    assert.deepStrictEqual(ran, [], 'not while the activation runs');
    vscode.window.onDidEndTerminalShellExecution.fire({ terminal: t, execution: activation });

    await until(() => ran.length > 0);
    assert.deepStrictEqual(ran, ['claude --resume abc']);
    assert.deepStrictEqual(vscode.log, [], 'run through shell integration, not typed');
  } finally {
    ext.stop();
  }
});

test('without shell integration a run still goes in once the shell has had a moment', async () => {
  const vscode = fakeVscode({ shellIntegrationApi: false });
  const ext = await start(vscode);
  try {
    const sent = Date.now();
    ext.send({ type: 'run', req: 2, cwd: '/proj', command: 'claude --resume abc' });
    await until(() => vscode.log.length > 0);
    assert.ok(Date.now() - sent >= 1000, 'not straight into a shell that is still starting');
    assert.deepStrictEqual(vscode.log, [['sendText', 'claude --resume abc', true]]);
  } finally {
    ext.stop();
  }
});

test('a folder that is not open is refused', async () => {
  const vscode = fakeVscode({ shellIntegrationApi: true });
  const ext = await start(vscode);
  try {
    ext.send({ type: 'run', req: 3, cwd: '/elsewhere', command: 'claude' });
    await until(() => ext.lines.some((l) => l.req === 3));
    assert.strictEqual(ext.lines.find((l) => l.req === 3).ok, false);
    assert.strictEqual(vscode.window.created, undefined);
  } finally {
    ext.stop();
  }
});

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../coding/coding_controller.dart';
import '../coding/coding_models.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

/// Native Coding tab — a control plane for tmux-backed Claude Code coding
/// sessions (the server's `coding_sessions` toolset). Lists sessions, drills
/// into one (status + a live terminal + restart/stop/delete + a per-session
/// settings sheet), and launches new ones from a sheet (with host / skip-perms
/// / cross-device sync parity with the WebUI).
///
/// Live terminal: we use the pure-Dart `xterm` package's [TerminalView], fed
/// by the session's SSE `output` stream (POST .../terminal/start then GET
/// /api/terminal/output). Keystrokes from the view post to /api/terminal/input
/// and dimension changes to /api/terminal/resize. No native PTY / flutter_pty
/// is involved — the PTY lives on the server.
class CodingPage extends StatefulWidget {
  const CodingPage({super.key});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> {
  late final CodingSessionsController _c = CodingSessionsController(app.api);
  final _composer = TextEditingController();

  // ── Live terminal (xterm) ──
  Terminal? _term;
  String? _termForId; // session id the current Terminal is built for
  StreamSubscription<String>? _termSub;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _c.loadSessions();
      _c.loadDevices();
    });
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    _termSub?.cancel();
    _c.dispose();
    _composer.dispose();
    super.dispose();
  }

  /// Build/tear-down the xterm [Terminal] in lock-step with the selection.
  void _onControllerChanged() {
    final id = _c.selectedId;
    if (id == null) {
      if (_term != null) {
        _termSub?.cancel();
        _termSub = null;
        _term = null;
        _termForId = null;
      }
      return;
    }
    if (_termForId != id) {
      _mountTerminal(id);
    }
  }

  void _mountTerminal(String id) {
    _termSub?.cancel();
    final term = Terminal(maxLines: 4000);
    // User keystrokes from the view -> server PTY.
    term.onOutput = (data) => _c.sendTerminalInput(data);
    // View dimension changes -> server PTY winsize.
    term.onResize = (w, h, _, __) => _c.resizeTerminal(rows: h, cols: w);
    _term = term;
    _termForId = id;
    // PTY output -> the view's buffer.
    _termSub = _c.terminalText.listen((text) {
      if (_termForId == id) term.write(text);
    });
    // Attach the server-side PTY and begin streaming.
    _c.startTerminal(rows: term.viewHeight, cols: term.viewWidth);
  }

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty || _c.sending) return;
    _composer.clear();
    _c.send(text);
    FocusScope.of(context).unfocus();
  }

  Future<void> _openLaunchSheet() async {
    _c.loadDevices(); // refresh the paired-devices list for the sync dropdown
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LaunchSheet(controller: _c),
    );
  }

  Future<void> _openSettingsSheet() async {
    final s = _c.selected;
    if (s == null) return;
    _c.loadDevices(); // refresh the paired-devices list for the sync dropdown
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(controller: _c, session: s),
    );
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Delete session',
            style: TextStyle(color: JcTheme.text)),
        content: const Text(
          'This stops the session and permanently removes it.',
          style: TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: JcTheme.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('Delete', style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _c.delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Coding',
        back: false,
        trailing: ListenableBuilder(
          listenable: _c,
          builder: (_, __) => GlassIconButton(
            icon: Icons.refresh_rounded,
            onTap: _c.loading ? null : _c.loadSessions,
            color: _c.loading ? JcTheme.muted : JcTheme.text,
          ),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) =>
                _c.hasSelection ? _buildDetail() : _buildList(),
          ),
        ),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _c,
        builder: (_, __) => _c.hasSelection
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: _c.launching ? null : _openLaunchSheet,
                backgroundColor: JcTheme.primaryBlue,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Launch'),
              ),
      ),
    );
  }

  // ── Sessions list ─────────────────────────────────────────────
  Widget _buildList() {
    if (_c.loading && _c.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_c.error != null && _c.sessions.isEmpty) {
      return _ErrorState(message: _c.error!, onRetry: _c.loadSessions);
    }
    return RefreshIndicator(
      onRefresh: _c.loadSessions,
      child: _c.sessions.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                _EmptyHint(),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: _c.sessions.length,
              itemBuilder: (_, i) {
                final s = _c.sessions[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: _SessionCard(
                    session: s,
                    onTap: () => _c.select(s.id),
                  ),
                );
              },
            ),
    );
  }

  // ── Selected session detail ───────────────────────────────────
  Widget _buildDetail() {
    final s = _c.selected;
    final live = s?.isLive ?? false;
    return Column(
      children: [
        // Header: back + title + status pill + settings
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.chevron_left_rounded,
                iconSize: 24,
                onTap: _c.deselect,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s?.displayTitle ?? 'Session',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((s?.cwd ?? '').isNotEmpty)
                      Text(
                        s!.cwd!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: JcTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(status: s?.status ?? 'starting'),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.tune_rounded,
                iconSize: 20,
                onTap: s == null ? null : _openSettingsSheet,
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_c.error != null) ...[
                  _InlineError(message: _c.error!),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    glassSectionLabel('Live terminal'),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '${(s?.host ?? 'server') == 'desktop' ? 'desktop' : 'server'} · type below',
                        style: const TextStyle(
                            color: JcTheme.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                Expanded(child: _buildTerminal()),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: GlassButton(
                        label: live ? 'Stop' : 'Restart',
                        icon: live
                            ? Icons.stop_rounded
                            : Icons.restart_alt_rounded,
                        ghost: live,
                        full: true,
                        onPressed: _c.busy
                            ? null
                            : (live ? _c.stop : _c.restart),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GlassButton(
                        label: 'Delete',
                        icon: Icons.delete_outline_rounded,
                        ghost: true,
                        full: true,
                        onPressed: _c.busy ? null : _confirmDelete,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _MessageComposer(
          controller: _composer,
          controllerRef: _c,
          onSend: _send,
        ),
      ],
    );
  }

  Widget _buildTerminal() {
    final term = _term;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: const Color(0xFF0A0D13),
        padding: const EdgeInsets.all(6),
        child: term == null
            ? const Center(
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: JcTheme.muted),
              )
            : ListenableBuilder(
                listenable: _c,
                builder: (context, _) {
                  if (_c.terminalError != null) {
                    return Center(
                      child: Text(
                        'Terminal unavailable:\n${_c.terminalError}',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: JcTheme.danger, fontSize: 12),
                      ),
                    );
                  }
                  return TerminalView(
                    term,
                    theme: _kTermTheme,
                    textStyle: const TerminalStyle(
                      fontSize: 12,
                      fontFamily: 'Menlo',
                    ),
                    backgroundOpacity: 0,
                    padding: EdgeInsets.zero,
                  );
                },
              ),
      ),
    );
  }
}

// A dark terminal theme close to the WebUI's #0a0d13 pane.
const TerminalTheme _kTermTheme = TerminalTheme(
  cursor: Color(0xFFE0E0E0),
  selection: Color(0x402E6BFF),
  foreground: Color(0xFFD7DAE0),
  background: Color(0xFF0A0D13),
  black: Color(0xFF2E3436),
  red: Color(0xFFFF6B7E),
  green: Color(0xFF5BE5A0),
  yellow: Color(0xFFE9C46A),
  blue: Color(0xFF6FB0FF),
  magenta: Color(0xFFB39DFF),
  cyan: Color(0xFF46E0E0),
  white: Color(0xFFD3D7CF),
  brightBlack: Color(0xFF555753),
  brightRed: Color(0xFFFF8A99),
  brightGreen: Color(0xFF8AF0C0),
  brightYellow: Color(0xFFFCE99B),
  brightBlue: Color(0xFF9CC9FF),
  brightMagenta: Color(0xFFCBBBFF),
  brightCyan: Color(0xFF7FF0F0),
  brightWhite: Color(0xFFEEEEEC),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

// ── Sessions list card ──────────────────────────────────────────
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onTap});

  final CodingSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final live = session.isLive;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (live ? JcTheme.success : JcTheme.muted)
                  .withValues(alpha: 0.12),
              border: Border.all(
                color: (live ? JcTheme.success : JcTheme.muted)
                    .withValues(alpha: 0.30),
              ),
            ),
            child: Icon(
              Icons.terminal_rounded,
              size: 20,
              color: live ? JcTheme.success : JcTheme.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if ((session.host ?? '').isNotEmpty) session.host!,
                    if ((session.branch ?? '').isNotEmpty) session.branch!,
                    if ((session.cwd ?? '').isNotEmpty)
                      session.cwd!.split('/').last,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusPill(status: session.status),
        ],
      ),
    );
  }
}

// ── Status pill ─────────────────────────────────────────────────
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  Color get _color {
    switch (status) {
      case 'running':
        return JcTheme.success;
      case 'starting':
      case 'idle':
        return JcTheme.primaryBlue;
      case 'error':
        return JcTheme.danger;
      case 'stopped':
      default:
        return JcTheme.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color.withValues(alpha: 0.30)),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: _color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Detail: message composer ────────────────────────────────────
class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.controllerRef,
    required this.onSend,
  });

  final TextEditingController controller;
  final CodingSessionsController controllerRef;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottomPad),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: JcTheme.glassFill,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(color: JcTheme.text, fontSize: 15),
                      decoration: const InputDecoration(
                        hintText: 'Message this session…',
                        hintStyle: TextStyle(color: JcTheme.muted),
                        filled: true,
                        fillColor: Colors.transparent,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 0, vertical: 10),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: controllerRef,
                  builder: (context, _) => GestureDetector(
                    onTap: controllerRef.sending ? null : onSend,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: controllerRef.sending ? null : blueGradient(),
                        color: controllerRef.sending ? JcTheme.glassFill : null,
                        shape: BoxShape.circle,
                        border: controllerRef.sending
                            ? Border.all(color: JcTheme.glassBorder)
                            : null,
                      ),
                      child: controllerRef.sending
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: JcTheme.muted,
                              ),
                            )
                          : const Icon(Icons.arrow_upward,
                              color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Launch sheet ────────────────────────────────────────────────
class _LaunchSheet extends StatefulWidget {
  const _LaunchSheet({required this.controller});
  final CodingSessionsController controller;

  @override
  State<_LaunchSheet> createState() => _LaunchSheetState();
}

class _LaunchSheetState extends State<_LaunchSheet> {
  final _cwd = TextEditingController();
  final _title = TextEditingController();
  final _model = TextEditingController();
  final _prompt = TextEditingController();
  final _syncPath = TextEditingController();

  String _host = 'server';
  bool _worktree = false;
  bool _skipPerms = false;
  bool _sync = false;
  String? _syncDevice; // selected device id (null = none chosen)

  @override
  void dispose() {
    _cwd.dispose();
    _title.dispose();
    _model.dispose();
    _prompt.dispose();
    _syncPath.dispose();
    super.dispose();
  }

  Future<void> _launch() async {
    final cwd = _cwd.text.trim();
    final prompt = _prompt.text.trim();
    if (cwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A working directory is required')),
      );
      return;
    }
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('An initial prompt is required')),
      );
      return;
    }
    final nav = Navigator.of(context);
    final sync = _sync
        ? CodingSync(
            enabled: true,
            device: (_syncDevice ?? '').trim(),
            remotePath: _syncPath.text.trim(),
          )
        : null;
    final session = await widget.controller.launch(
      cwd: cwd,
      repoPath: cwd, // send both keys so either server naming works
      worktree: _worktree,
      title: _title.text.trim(),
      prompt: prompt,
      model: _model.text.trim(),
      host: _host,
      skipPermissions: _skipPerms,
      sync: sync,
    );
    if (!mounted) return;
    if (session != null) {
      nav.pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.controller.error ?? 'Launch failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: JcTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetGrabber(),
              const Text(
                'Launch coding session',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Working directory'),
              TextField(
                controller: _cwd,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '~/code/your-project  (~ expands, created if new)',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Title (optional)'),
              TextField(
                controller: _title,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'What are we building?',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Model (optional)'),
              TextField(
                controller: _model,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'e.g. claude-opus-4-8 (blank = server default)',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Run on'),
              _HostPicker(
                value: _host,
                onChanged: (v) => setState(() => _host = v),
              ),
              const SizedBox(height: 6),
              _Toggle(
                value: _worktree,
                onChanged: (v) => setState(() => _worktree = v),
                title: 'Run in an isolated git worktree',
                subtitle: 'Branches a fresh worktree from the directory above.',
              ),
              _Toggle(
                value: _skipPerms,
                onChanged: (v) => setState(() => _skipPerms = v),
                title: 'Dangerously skip permissions',
                subtitle: 'Autonomous — no approval prompts.',
              ),
              _Toggle(
                value: _sync,
                onChanged: (v) => setState(() => _sync = v),
                title: 'Sync this project with another device',
                subtitle: 'Two-way file sync with a paired device.',
              ),
              if (_sync) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('Device'),
                      ListenableBuilder(
                        listenable: widget.controller,
                        builder: (_, __) => _DeviceDropdown(
                          devices: widget.controller.devices,
                          value: _syncDevice,
                          onChanged: (v) => setState(() => _syncDevice = v),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const _FieldLabel('Folder path on that device'),
                      TextField(
                        controller: _syncPath,
                        style:
                            const TextStyle(color: JcTheme.text, fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: '~/code/your-project',
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'On launch: a populated remote folder is pulled to the '
                        'server; an empty one is pushed to. Two-way sync then '
                        'keeps them in step.',
                        style: TextStyle(color: JcTheme.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              const _FieldLabel('Initial prompt'),
              TextField(
                controller: _prompt,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Describe the task for the coding agent…',
                ),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: widget.controller,
                builder: (_, __) => GlassButton(
                  label: widget.controller.launching ? 'Launching…' : 'Launch',
                  icon: Icons.rocket_launch_rounded,
                  full: true,
                  onPressed: widget.controller.launching ? null : _launch,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Per-session settings sheet ──────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.controller, required this.session});
  final CodingSessionsController controller;
  final CodingSession session;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _skipPerms = widget.session.skipPermissions;
  late bool _sync = widget.session.sync?.enabled ?? false;
  late final _syncPath = TextEditingController(
      text: widget.session.sync?.remotePath ?? '');
  late final _cwd =
      TextEditingController(text: widget.session.cwd ?? '');
  // Selected device id/name; seeded from the saved sync config. Null = none.
  late String? _syncDevice = () {
    final d = (widget.session.sync?.device ?? '').trim();
    return d.isEmpty ? null : d;
  }();
  bool _saving = false;

  @override
  void dispose() {
    _syncPath.dispose();
    _cwd.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.controller.saveSettings(
      skipPermissions: _skipPerms,
      cwd: _cwd.text.trim(),
      sync: CodingSync(
        enabled: _sync,
        device: (_syncDevice ?? '').trim(),
        remotePath: _syncPath.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.controller.error ?? 'Save failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: JcTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetGrabber(),
              const Text(
                'Session settings',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              _ReadOnlyKv('Run on', (s.host ?? 'server')),
              _ReadOnlyKv('Model', s.model ?? 'server default'),
              const SizedBox(height: 8),
              const _FieldLabel('Working directory'),
              TextField(
                controller: _cwd,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(hintText: '~/code/project'),
              ),
              const SizedBox(height: 6),
              _Toggle(
                value: _skipPerms,
                onChanged: (v) => setState(() => _skipPerms = v),
                title: 'Dangerously skip permissions',
                subtitle: 'Autonomous — no approval prompts.',
              ),
              _Toggle(
                value: _sync,
                onChanged: (v) => setState(() => _sync = v),
                title: 'Sync with another device',
                subtitle: (s.sync?.device ?? '').isEmpty
                    ? 'Two-way file sync.'
                    : 'Device: ${s.sync!.device}',
              ),
              if (_sync) ...[
                const SizedBox(height: 8),
                const _FieldLabel('Device'),
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (_, __) => _DeviceDropdown(
                    devices: widget.controller.devices,
                    value: _syncDevice,
                    onChanged: (v) => setState(() => _syncDevice = v),
                  ),
                ),
                const SizedBox(height: 12),
                const _FieldLabel('Folder path on that device'),
                TextField(
                  controller: _syncPath,
                  style: const TextStyle(color: JcTheme.text, fontSize: 14),
                  decoration:
                      const InputDecoration(hintText: '~/code/your-project'),
                ),
              ],
              const SizedBox(height: 18),
              GlassButton(
                label: _saving ? 'Saving…' : 'Save settings',
                icon: Icons.check_rounded,
                full: true,
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyKv extends StatelessWidget {
  const _ReadOnlyKv(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: JcTheme.text,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Small shared widgets ────────────────────────────────────────
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: JcTheme.muted.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _HostPicker extends StatelessWidget {
  const _HostPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String v, String label) {
      final sel = value == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(v),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: sel
                  ? JcTheme.primaryBlue.withValues(alpha: 0.20)
                  : JcTheme.glassFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: sel ? JcTheme.primaryBlue : JcTheme.glassBorder,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: sel ? JcTheme.text : JcTheme.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('server', 'This server'),
        chip('desktop', 'My computer'),
      ],
    );
  }
}

/// Dropdown of paired/registered devices for the sync "Device" field
/// (parity with the WebUI). Value = device id; label = name (+ " (offline)"
/// when not online). A leading "— choose a device —" empty option clears it,
/// and a previously-saved value missing from the current list is preserved as
/// a synthetic "… (not connected)" item.
class _DeviceDropdown extends StatelessWidget {
  const _DeviceDropdown({
    required this.devices,
    required this.value,
    required this.onChanged,
  });

  final List<CodingDevice> devices;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final sel = (value ?? '').trim();
    // Match a saved value by id OR name (settings may have stored either).
    final inList = devices.any((d) => d.id == sel || d.name == sel);

    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: '',
        child: Text(
          '— choose a device —',
          style: TextStyle(color: JcTheme.muted, fontSize: 14),
        ),
      ),
      for (final d in devices)
        DropdownMenuItem<String>(
          value: d.id,
          child: Text(
            d.online ? d.name : '${d.name} (offline)',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: JcTheme.text, fontSize: 14),
          ),
        ),
      // Preserve a previously-saved value even if its device isn't listed now.
      if (sel.isNotEmpty && !inList)
        DropdownMenuItem<String>(
          value: sel,
          child: Text(
            '$sel (not connected)',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: JcTheme.text, fontSize: 14),
          ),
        ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: sel.isEmpty ? '' : sel,
          isExpanded: true,
          dropdownColor: JcTheme.surface,
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.expand_more_rounded, color: JcTheme.muted),
          style: const TextStyle(color: JcTheme.text, fontSize: 14),
          items: items,
          onChanged: (v) => onChanged((v ?? '').isEmpty ? null : v),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeThumbColor: JcTheme.primaryBlue,
      title: Text(title,
          style: const TextStyle(color: JcTheme.text, fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: JcTheme.muted,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Shared small pieces ─────────────────────────────────────────
class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            Icon(Icons.terminal_rounded, size: 40, color: JcTheme.muted),
            SizedBox(height: 14),
            Text(
              'No coding sessions yet',
              style: TextStyle(
                color: JcTheme.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Launch a Claude Code session on a project to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: JcTheme.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: JcTheme.danger, size: 32),
              const SizedBox(height: 12),
              Text(
                message,
                style: const TextStyle(color: JcTheme.danger, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              GlassButton(
                label: 'Retry',
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: JcTheme.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: JcTheme.danger.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: JcTheme.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: JcTheme.danger, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

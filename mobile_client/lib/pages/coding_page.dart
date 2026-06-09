import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // Poll the list for live status only while the Coding tab is actually
    // visible (every page lives forever in NavShell's IndexedStack, so initState
    // alone would poll for the whole app lifetime).
    app.activeTabIndex.addListener(_onTabVisibility);
    _onTabVisibility();
  }

  void _onTabVisibility() {
    _c.setListPolling(app.activeTabIndex.value == app.kCodingTabIndex);
  }

  @override
  void dispose() {
    app.activeTabIndex.removeListener(_onTabVisibility);
    _c.removeListener(_onControllerChanged);
    _termSub?.cancel();
    _c.dispose();
    _composer.dispose();
    super.dispose();
  }

  /// Build/tear-down the xterm [Terminal] in lock-step with the selection.
  void _onControllerChanged() {
    final id = _c.selectedId;
    // No live terminal for an ENDED session (claude quit / tmux gone) — tearing
    // it down avoids re-attaching a dead tmux, and the detail view shows the
    // recovery panel instead. (Also covers the no-selection case.)
    if (id == null || (_c.selected?.isEnded ?? false)) {
      if (_term != null) {
        _termSub?.cancel();
        _termSub = null;
        _term = null;
        _termForId = null;
        // Also detach the controller's server-side PTY/SSE so a session that
        // just ended doesn't leave the dead-tmux stream dangling (idempotent).
        _c.detachTerminal();
      }
      return;
    }
    if (_termForId != id) {
      _mountTerminal(id);
    }
  }

  /// Re-attempt the terminal for a session whose terminal ended: drop the stale
  /// page-side terminal so a now-live session re-mounts, then ask the controller
  /// to refresh the detail (a still-ended one stays on the recovery panel).
  Future<void> _reopenTerminal() async {
    _termSub?.cancel();
    _termSub = null;
    _term = null;
    _termForId = null;
    await _c.reopenTerminal();
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
          builder: (_, __) => _c.hasSelection
              ? GlassIconButton(
                  icon: Icons.refresh_rounded,
                  onTap: _c.loading ? null : _c.loadSessions,
                  color: _c.loading ? JcTheme.muted : JcTheme.text,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GlassIconButton(
                      icon: Icons.radar_rounded,
                      iconSize: 20,
                      onTap: _c.busyProjects ? null : _rescanDiscovered,
                      color: _c.busyProjects ? JcTheme.muted : JcTheme.text,
                    ),
                    const SizedBox(width: 8),
                    GlassIconButton(
                      icon: Icons.refresh_rounded,
                      onTap: _c.loading ? null : _c.loadSessions,
                      color: _c.loading ? JcTheme.muted : JcTheme.text,
                    ),
                  ],
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
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FloatingActionButton.extended(
                    heroTag: 'coding-new-project',
                    onPressed: _c.busyProjects ? null : _newProject,
                    backgroundColor: JcTheme.surfaceAlt,
                    foregroundColor: JcTheme.text,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Project'),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton.extended(
                    heroTag: 'coding-launch',
                    onPressed: _c.launching ? null : _openLaunchSheet,
                    backgroundColor: JcTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Launch'),
                  ),
                ],
              ),
      ),
    );
  }

  // ── Projects → Sessions list ──────────────────────────────────
  Widget _buildList() {
    if (_c.loading && _c.sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_c.error != null && _c.sessions.isEmpty) {
      return _ErrorState(message: _c.error!, onRetry: _c.loadSessions);
    }
    final hasAnything =
        _c.projects.isNotEmpty || _c.ungrouped.isNotEmpty || _c.sessions.isNotEmpty;
    if (!hasAnything) {
      return RefreshIndicator(
        onRefresh: _c.loadSessions,
        child: ListView(
          children: const [SizedBox(height: 120), _EmptyHint()],
        ),
      );
    }

    // Build the group list: real projects (with actions) then a synthetic
    // "Ungrouped" bucket of project-less sessions (only when non-empty).
    final groups = <Widget>[];
    for (final p in _c.projects) {
      groups.add(_ProjectGroup(
        controller: _c,
        groupKey: p.id,
        name: p.name.isNotEmpty
            ? p.name
            : (p.repoPath ?? 'project ${p.id}'),
        subtitle: p.repoPath,
        sessions: p.sessions,
        collapsed: _c.isCollapsed(p.id),
        onToggle: () => _c.toggleCollapsed(p.id),
        onSelect: _c.select,
        onResume: _resumeSession,
        onNewSession: () => _newSessionInProject(p),
        onSettings: () => _openProjectSettings(p),
      ));
    }
    // Older backends: if there are no projects but a flat list exists, fold it
    // into Ungrouped so nothing is hidden.
    var loose = _c.ungrouped;
    if (_c.projects.isEmpty && _c.ungrouped.isEmpty && _c.sessions.isNotEmpty) {
      loose = _c.sessions;
    }
    if (loose.isNotEmpty) {
      groups.add(_ProjectGroup(
        controller: _c,
        groupKey: CodingSessionsController.ungroupedKey,
        name: 'Ungrouped',
        subtitle: null,
        sessions: loose,
        collapsed: _c.isCollapsed(CodingSessionsController.ungroupedKey),
        onToggle: () =>
            _c.toggleCollapsed(CodingSessionsController.ungroupedKey),
        onSelect: _c.select,
        onResume: _resumeSession,
        onNewSession: null, // ungrouped has no project to launch into
        onSettings: null,
      ));
    }

    return RefreshIndicator(
      onRefresh: _c.loadSessions,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
        children: [
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: g,
            ),
        ],
      ),
    );
  }

  // ── Project / discovered actions ──────────────────────────────
  Future<void> _rescanDiscovered() async {
    await _c.discoverRefresh();
    if (mounted && _c.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_c.error!)));
    }
  }

  Future<void> _resumeSession(String id) async {
    final openId = await _c.resumeSession(id);
    if (!mounted) return;
    if (openId != null) {
      await _c.select(openId);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_c.error ??
                'Could not resume this session (is the device online?).')),
      );
    }
  }

  Future<void> _newProject() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NewProjectSheet(controller: _c),
    );
  }

  Future<void> _newSessionInProject(CodingProject project) async {
    _c.loadDevices(); // refresh the paired-devices list for the sync dropdown
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LaunchSheet(controller: _c, project: project),
    );
  }

  Future<void> _openProjectSettings(CodingProject project) async {
    _c.loadDevices(); // refresh the paired-devices list for the sync dropdown
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ProjectSettingsSheet(controller: _c, project: project),
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
              // Condensed lifecycle controls live in the header now (Stop/Restart
              // toggle + Delete), freeing the space below the terminal for the
              // console key bar. Hidden for an ended session (the recovery panel
              // owns those actions).
              if (s != null && !s.isEnded) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: live ? Icons.stop_rounded : Icons.restart_alt_rounded,
                  iconSize: 18,
                  size: 36,
                  color: live ? JcTheme.danger : JcTheme.primaryBlue,
                  onTap: _c.busy ? null : (live ? _c.stop : _c.restart),
                ),
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: Icons.delete_outline_rounded,
                  iconSize: 18,
                  size: 36,
                  onTap: _c.busy ? null : _confirmDelete,
                ),
              ],
              const SizedBox(width: 6),
              GlassIconButton(
                icon: Icons.tune_rounded,
                iconSize: 20,
                size: 36,
                onTap: s == null ? null : _openSettingsSheet,
              ),
            ],
          ),
        ),
        // The body SCROLLS as a page (so the sync card, buttons, etc. are always
        // reachable even with the keyboard up / a tall error), while the live
        // terminal keeps its OWN scrollback inside a generous fixed-height box —
        // dragging on the terminal scrolls the terminal; dragging elsewhere
        // scrolls the page.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_c.error != null) ...[
                  _InlineError(message: _c.error!),
                  const SizedBox(height: 12),
                ],
                if (_c.sync?.enabled == true) ...[
                  _SyncCard(
                    sync: _c.sync!,
                    onRefresh: _c.refreshSync,
                  ),
                  const SizedBox(height: 12),
                ],
                if (s?.isEnded == true)
                  _EndedPanel(
                    session: s!,
                    busy: _c.busy,
                    onRelaunchDevice: () => _c.relaunchOnDevice(),
                    onResumeServer: () => _resumeSession(s.id),
                    onReopenTerminal: () => _reopenTerminal(),
                    onRestart: () => _c.restart(),
                    onDelete: () => _confirmDelete(),
                  )
                else ...[
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
                  SizedBox(
                    height: (MediaQuery.of(context).size.height * 0.42)
                        .clamp(220.0, 560.0),
                    child: _buildTerminal(),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
        // The console KEY BAR + composer are FIXED below the scrolling body (so
        // they stay reachable with the keyboard up). The key bar drives
        // interactive TUI prompts (selection menus, permission boxes) that a soft
        // keyboard can't — arrows / Enter / Esc / number-select / Tab / Ctrl-C.
        if (s?.isEnded != true) ...[
          _TerminalKeyBar(
            onKey: _c.sendTerminalInput,
            enabled: _term != null,
          ),
          _MessageComposer(
            controller: _composer,
            controllerRef: _c,
            onSend: _send,
          ),
        ],
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
                  // The live Terminal in a Stack with a fullscreen toggle in the
                  // corner. Tapping it pushes a full-screen route that renders
                  // the SAME Terminal object, so the live session fills the
                  // device (mirrors the WebUI's ⛶ Fullscreen).
                  return Stack(
                    children: [
                      Positioned.fill(child: _termView(term)),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          icon: const Icon(Icons.fullscreen,
                              color: JcTheme.muted, size: 22),
                          tooltip: 'Fullscreen',
                          onPressed: () => _openFullscreenTerminal(term),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  // The bare TerminalView, shared between the inline card and the fullscreen
  // route (xterm renders the same live [Terminal] in both places).
  Widget _termView(Terminal term) => TerminalView(
        term,
        theme: _kTermTheme,
        textStyle: const TerminalStyle(fontSize: 12, fontFamily: 'Menlo'),
        backgroundOpacity: 0,
        padding: EdgeInsets.zero,
      );

  void _openFullscreenTerminal(Terminal term) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: const Color(0xFF0A0D13),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: _termView(term),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Icons.fullscreen_exit,
                      color: JcTheme.muted, size: 26),
                  tooltip: 'Exit fullscreen',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
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

// ── Project group (collapsible header + nested session rows) ─────
/// One project group in the tree: a tappable header (caret + name + count +
/// optional + / ⚙ actions) over its session rows. The synthetic "Ungrouped"
/// bucket passes [onNewSession]/[onSettings] null so it shows no header actions.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup({
    required this.controller,
    required this.groupKey,
    required this.name,
    required this.subtitle,
    required this.sessions,
    required this.collapsed,
    required this.onToggle,
    required this.onSelect,
    required this.onResume,
    required this.onNewSession,
    required this.onSettings,
  });

  final CodingSessionsController controller;
  final String groupKey;
  final String name;
  final String? subtitle;
  final List<CodingSession> sessions;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;
  final Future<void> Function(String id) onResume;
  final VoidCallback? onNewSession;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    // Newest-first by numeric recency (last_activity_at, then created_at).
    final sorted = sessions.toList()
      ..sort((a, b) => b.recencyTs.compareTo(a.recencyTs));
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Material(
            color: Colors.transparent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: InkWell(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  children: [
                    Icon(
                      collapsed
                          ? Icons.chevron_right_rounded
                          : Icons.expand_more_rounded,
                      size: 22,
                      color: JcTheme.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: JcTheme.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if ((subtitle ?? '').isNotEmpty)
                            Text(
                              subtitle!,
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
                    _CountChip(count: sorted.length),
                    if (onNewSession != null)
                      IconButton(
                        icon: const Icon(Icons.add_rounded,
                            size: 20, color: JcTheme.muted),
                        tooltip: 'New session in this project',
                        onPressed: onNewSession,
                      ),
                    if (onSettings != null)
                      IconButton(
                        icon: const Icon(Icons.tune_rounded,
                            size: 18, color: JcTheme.muted),
                        tooltip: 'Project settings',
                        onPressed: onSettings,
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Body
          if (!collapsed)
            if (sorted.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 16, 14),
                child: Text(
                  'No sessions yet.',
                  style: TextStyle(color: JcTheme.muted, fontSize: 13),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  children: [
                    for (final s in sorted)
                      _SessionRow(
                        session: s,
                        selected: controller.selectedId == s.id,
                        onTap: () => onSelect(s.id),
                        onResume: () => onResume(s.id),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// A small count badge shown in a project header.
class _CountChip extends StatelessWidget {
  const _CountChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: JcTheme.muted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Nested session row (inside a project group) ─────────────────
/// One session row. Shows a status dot, title, source/host badge + path, and
/// (for an idle discovered-transcript session) an inline Resume button instead
/// of opening the live terminal. A transcript-idle row is NOT tappable-to-open
/// — it has no live tmux; Resume relaunches it on its device first.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onResume,
  });

  final CodingSession session;
  final bool selected;
  final VoidCallback onTap;
  final Future<void> Function() onResume;

  // Live activity states (Scheme 4): working green, waiting purple, idle grey.
  Color _dotColor(String cls) {
    switch (cls) {
      case 'working':
        return const Color(0xFF34D399);
      case 'waiting':
        return const Color(0xFFC084FC);
      case 'running':
        return JcTheme.success;
      case 'done':
        return JcTheme.primaryBlue;
      case 'error':
        return JcTheme.danger;
      case 'idle':
        return const Color(0xFF838B97);
      case 'stopped':
        return JcTheme.muted;
      default:
        return JcTheme.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final transcriptIdle = session.isTranscriptIdle;
    // liveState refines a running session into working/waiting/idle and returns
    // 'history' for an idle transcript.
    final cls = session.liveState;
    final dot = _dotColor(cls);
    final sub = (session.cwd ?? '').trim();
    final badge = session.badge;
    return Material(
      color: selected
          ? JcTheme.primaryBlue.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // Idle transcripts can't open a live terminal — Resume them first.
        onTap: transcriptIdle ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dot,
                    border: session.statusClass == 'running'
                        ? null
                        : Border.all(
                            color: JcTheme.muted.withValues(alpha: 0.5)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _SourceBadge(kind: badge.kind, label: badge.label),
                        if (sub.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: JcTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ] else
                          const Spacer(),
                      ],
                    ),
                  ],
                ),
              ),
              if (transcriptIdle) ...[
                const SizedBox(width: 8),
                _ResumeButton(onResume: onResume),
              ] else if (!transcriptIdle)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 20, color: JcTheme.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The host/source badge: server / desktop / discovered (or live) / history.
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.kind, required this.label});
  final String kind;
  final String label;

  Color get _color {
    switch (kind) {
      case 'discovered':
        return JcTheme.cyan;
      case 'desktop':
        return JcTheme.accent;
      case 'history':
        return JcTheme.muted;
      case 'server':
      default:
        return JcTheme.primaryBlueHi;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: c,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Inline Resume affordance for an idle discovered-transcript session, with a
/// tiny in-flight spinner while the resume request runs.
class _ResumeButton extends StatefulWidget {
  const _ResumeButton({required this.onResume});
  final Future<void> Function() onResume;

  @override
  State<_ResumeButton> createState() => _ResumeButtonState();
}

class _ResumeButtonState extends State<_ResumeButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResume();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _busy ? null : _run,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: JcTheme.primaryBlue.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: JcTheme.primaryBlue.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: JcTheme.primaryBlueHi),
                )
              else
                const Icon(Icons.play_arrow_rounded,
                    size: 16, color: JcTheme.primaryBlueHi),
              const SizedBox(width: 4),
              Text(
                _busy ? 'Resuming…' : 'Resume',
                style: const TextStyle(
                  color: JcTheme.primaryBlueHi,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
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

// ── Ended-session recovery panel ────────────────────────────────
/// Shown instead of the live terminal when a session has ENDED (claude quit /
/// its tmux is gone). Mirrors the WebUI's ended panel: a host-aware set of
/// recovery actions. A SERVER session offers Restart / Delete; a DISCOVERED Mac
/// session offers Relaunch on device / Resume on server / Reopen terminal.
class _EndedPanel extends StatelessWidget {
  const _EndedPanel({
    required this.session,
    required this.busy,
    required this.onRelaunchDevice,
    required this.onResumeServer,
    required this.onReopenTerminal,
    required this.onRestart,
    required this.onDelete,
  });

  final CodingSession session;
  final bool busy;
  final VoidCallback onRelaunchDevice;
  final VoidCallback onResumeServer;
  final VoidCallback onReopenTerminal;
  final VoidCallback onRestart;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isServer = (session.host ?? 'server') == 'server' &&
        !(session.source ?? '').startsWith('discovered');
    final hint = isServer
        ? 'The claude for this session has stopped (you quit it / its tmux ended). '
            'There’s no live terminal — Restart launches it again in the same '
            'folder on the server.'
        : 'The live claude for this session has stopped (its tmux session ended). '
            'There’s no live terminal to attach. Relaunch it on the device to keep '
            'working there, or resume it on the server (it continues from the '
            'synced transcript).';
    final actions = isServer
        ? <Widget>[
            GlassButton(
              label: 'Restart',
              icon: Icons.restart_alt_rounded,
              full: true,
              onPressed: busy ? null : onRestart,
            ),
            const SizedBox(height: 10),
            GlassButton(
              label: 'Delete',
              icon: Icons.delete_outline_rounded,
              ghost: true,
              full: true,
              onPressed: busy ? null : onDelete,
            ),
          ]
        : <Widget>[
            GlassButton(
              label: 'Relaunch on device',
              icon: Icons.devices_rounded,
              full: true,
              onPressed: busy ? null : onRelaunchDevice,
            ),
            const SizedBox(height: 10),
            GlassButton(
              label: 'Resume on server',
              icon: Icons.cloud_sync_rounded,
              ghost: true,
              full: true,
              onPressed: busy ? null : onResumeServer,
            ),
            const SizedBox(height: 10),
            GlassButton(
              label: 'Reopen terminal',
              icon: Icons.refresh_rounded,
              ghost: true,
              full: true,
              onPressed: busy ? null : onReopenTerminal,
            ),
          ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: JcTheme.surface.withValues(alpha: 0.40),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JcTheme.muted.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.power_settings_new_rounded,
                  size: 18, color: JcTheme.muted),
              SizedBox(width: 8),
              Text(
                'Session ended',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            style: const TextStyle(
                color: JcTheme.muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
          ...actions,
        ],
      ),
    );
  }
}

// ── Console key bar ─────────────────────────────────────────────
/// A fixed 2-row keypad below the live terminal that sends raw key SEQUENCES to
/// the server PTY (via /api/terminal/input). It makes interactive TUI prompts a
/// soft keyboard can't drive usable on mobile: selection menus (↑/↓ + Enter, or
/// number-select 1-6), permission boxes, Esc-to-cancel, the ⇧Tab permission-mode
/// cycler, and Ctrl-C. Sequences are the standard xterm encodings.
class _TerminalKeyBar extends StatelessWidget {
  const _TerminalKeyBar({required this.onKey, this.enabled = true});

  /// Sends a raw byte sequence straight to the PTY (no echo/translation).
  final void Function(String seq) onKey;
  final bool enabled;

  // Arrows use NORMAL cursor-key mode (CSI A/B). Claude Code's TUI reads these
  // for menu nav; if a future TUI enables application-cursor-keys (DECCKM) it
  // would expect SS3 (\x1bOA/\x1bOB) instead — switch here if menu arrows ever
  // misbehave.
  static const List<List<String>> _row1 = [
    ['Esc', '\x1b'],
    ['↑', '\x1b[A'],
    ['↓', '\x1b[B'],
    ['⏎', '\r'],
    ['^C', '\x03'],
  ];
  static const List<List<String>> _row2 = [
    ['1', '1'],
    ['2', '2'],
    ['3', '3'],
    ['4', '4'],
    ['5', '5'],
    ['6', '6'],
    ['⇥', '\t'],
    ['⇧⇥', '\x1b[Z'],
  ];

  Widget _row(List<List<String>> keys) => Row(
        children: [
          for (final k in keys)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _KeyButton(
                  label: k[0],
                  onTap: enabled
                      ? () {
                          HapticFeedback.selectionClick();
                          onKey(k[1]);
                        }
                      : null,
                ),
              ),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 8, 13, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(_row1),
          const SizedBox(height: 8),
          _row(_row2),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: JcTheme.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: JcTheme.muted.withValues(alpha: 0.22)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: JcTheme.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sync status card ────────────────────────────────────────────
/// Cross-device sync panel shown in the session detail (parity with the
/// WebUI). A colored dot + device + online/disconnected, a status label, a
/// progress bar while syncing (done/total · pct%), and a Refresh button.
class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.sync, required this.onRefresh});

  final CodingSyncStatus sync;
  final Future<void> Function() onRefresh;

  // Status label, matching the web's mapping. Offline overrides everything
  // except an explicit "disconnected" (which is already the offline message).
  String get _label {
    final online = sync.deviceOnline;
    if (!online && sync.status != 'disconnected') return 'Device offline';
    switch (sync.status) {
      case 'synced':
        return 'Up to date';
      case 'syncing':
        return 'Syncing…';
      case 'opening':
      case 'connecting':
        return 'Connecting…';
      case 'conflicts':
        return sync.conflicts > 1
            ? '${sync.conflicts} conflicts'
            : '${sync.conflicts} conflict';
      case 'idle':
        return online ? 'Idle' : 'Waiting for device';
      case 'disconnected':
        return 'Device offline';
      case 'error':
        return 'Error';
      default:
        return sync.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = sync.deviceOnline;
    final dotColor = online ? JcTheme.success : JcTheme.muted;
    final syncing = sync.isSyncing;
    final hasTotal = syncing && sync.total > 0;
    final pct = hasTotal ? ((sync.done / sync.total) * 100).round() : 0;
    final isError = sync.status == 'error';

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Head: "Sync" + Refresh
          Row(
            children: [
              const Text(
                'Sync',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _MiniButton(label: 'Refresh', onTap: onRefresh),
            ],
          ),
          const SizedBox(height: 10),
          // Device line: dot + name + online/disconnected + status label
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  (sync.device ?? '').trim().isEmpty ? 'device' : sync.device!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                online ? 'online' : 'disconnected',
                style: const TextStyle(color: JcTheme.muted, fontSize: 12),
              ),
              const Spacer(),
              Text(
                _label,
                style: TextStyle(
                  color: isError ? JcTheme.danger : JcTheme.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          // Progress bar while syncing
          if (syncing) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: hasTotal ? (sync.done / sync.total).clamp(0.0, 1.0) : null,
                minHeight: 6,
                backgroundColor: JcTheme.glassFill,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(JcTheme.primaryBlue),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasTotal
                  ? '${sync.done}/${sync.total} files · $pct%'
                  : 'Syncing…',
              style: const TextStyle(color: JcTheme.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// A compact glass pill button (used for the Sync card's Refresh action), with
/// a tiny in-flight spinner while the async action runs.
class _MiniButton extends StatefulWidget {
  const _MiniButton({required this.label, required this.onTap});
  final String label;
  final Future<void> Function() onTap;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onTap();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _busy ? null : _run,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: JcTheme.glassFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: JcTheme.muted),
                )
              else
                const Icon(Icons.refresh_rounded,
                    size: 14, color: JcTheme.muted),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
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

// ── New-project sheet ───────────────────────────────────────────
/// Create a project: name + repo path (+ optional default branch). Mirrors the
/// WebUI's "+ Project" flow (POST /api/coding/projects).
class _NewProjectSheet extends StatefulWidget {
  const _NewProjectSheet({required this.controller});
  final CodingSessionsController controller;

  @override
  State<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<_NewProjectSheet> {
  final _name = TextEditingController();
  final _repo = TextEditingController();
  final _branch = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    final repo = _repo.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A project name is required')),
      );
      return;
    }
    if (repo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A repo path is required')),
      );
      return;
    }
    setState(() => _saving = true);
    final id = await widget.controller.createProject(
      name: name,
      repoPath: repo,
      defaultBranch: _branch.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (id != null) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(widget.controller.error ?? 'Could not create project')),
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
                'New project',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Project name'),
              TextField(
                controller: _name,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(hintText: 'My project'),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Repo path on the server'),
              TextField(
                controller: _repo,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '~/code/my-project',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Default branch (optional)'),
              TextField(
                controller: _branch,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(hintText: 'main'),
              ),
              const SizedBox(height: 18),
              GlassButton(
                label: _saving ? 'Creating…' : 'Create project',
                icon: Icons.create_new_folder_outlined,
                full: true,
                onPressed: _saving ? null : _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Project-settings sheet ──────────────────────────────────────
/// Rename a project, toggle its cross-device sync (device + folder), edit its
/// default branch + ignore rules, or delete it. Mirrors the WebUI's project
/// settings panel (POST /project/<id>, DELETE /project/<id>).
class _ProjectSettingsSheet extends StatefulWidget {
  const _ProjectSettingsSheet({required this.controller, required this.project});
  final CodingSessionsController controller;
  final CodingProject project;

  @override
  State<_ProjectSettingsSheet> createState() => _ProjectSettingsSheetState();
}

class _ProjectSettingsSheetState extends State<_ProjectSettingsSheet> {
  late final _name = TextEditingController(text: widget.project.name);
  late final _branch =
      TextEditingController(text: widget.project.defaultBranch ?? '');
  late final _syncPath =
      TextEditingController(text: widget.project.syncDesktopPath ?? '');
  late final _ignore =
      TextEditingController(text: widget.project.ignoreRules ?? '');
  late bool _sync = widget.project.syncEnabled;
  late String? _syncDevice = () {
    final d = (widget.project.deviceId ?? '').trim();
    return d.isEmpty ? null : d;
  }();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _branch.dispose();
    _syncPath.dispose();
    _ignore.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A project name is required')),
      );
      return;
    }
    setState(() => _saving = true);
    final ok = await widget.controller.updateProject(
      widget.project.id,
      name: name,
      defaultBranch: _branch.text.trim(),
      syncEnabled: _sync,
      syncDesktopPath: _syncPath.text.trim(),
      ignoreRules: _ignore.text,
      deviceId: (_syncDevice ?? '').trim(),
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

  Future<void> _delete() async {
    final count = widget.project.sessions.length;
    final nav = Navigator.of(context);
    bool? cascade;
    if (count > 0) {
      cascade = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: JcTheme.surface,
          title: const Text('Delete project',
              style: TextStyle(color: JcTheme.text)),
          content: Text(
            'This project has $count session(s).\n\n'
            'Delete and also STOP + remove its sessions, or keep them '
            '(they move to Ungrouped)?',
            style: const TextStyle(color: JcTheme.muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child:
                  const Text('Cancel', style: TextStyle(color: JcTheme.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep sessions',
                  style: TextStyle(color: JcTheme.text)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete all',
                  style: TextStyle(color: JcTheme.danger)),
            ),
          ],
        ),
      );
      if (cascade == null) return; // cancelled
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: JcTheme.surface,
          title: const Text('Delete project',
              style: TextStyle(color: JcTheme.text)),
          content: const Text('Delete this project?',
              style: TextStyle(color: JcTheme.muted)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  const Text('Cancel', style: TextStyle(color: JcTheme.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child:
                  const Text('Delete', style: TextStyle(color: JcTheme.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
      cascade = false;
    }
    setState(() => _saving = true);
    final done =
        await widget.controller.deleteProject(widget.project.id, cascade: cascade);
    if (!mounted) return;
    setState(() => _saving = false);
    if (done) {
      nav.pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.controller.error ?? 'Delete failed')),
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
                'Project settings',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if ((widget.project.repoPath ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  widget.project.repoPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              const _FieldLabel('Name'),
              TextField(
                controller: _name,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(hintText: 'Project name'),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Default branch (optional)'),
              TextField(
                controller: _branch,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(hintText: 'main'),
              ),
              const SizedBox(height: 6),
              _Toggle(
                value: _sync,
                onChanged: (v) => setState(() => _sync = v),
                title: 'Sync this project with a desktop device',
                subtitle: 'Two-way file sync with a paired device.',
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
              const SizedBox(height: 14),
              const _FieldLabel('Ignore rules (optional, one per line)'),
              TextField(
                controller: _ignore,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'node_modules/\n.venv/\n*.log',
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Delete',
                      icon: Icons.delete_outline_rounded,
                      ghost: true,
                      full: true,
                      onPressed: _saving ? null : _delete,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassButton(
                      label: _saving ? 'Saving…' : 'Save',
                      icon: Icons.check_rounded,
                      full: true,
                      onPressed: _saving ? null : _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Launch sheet ────────────────────────────────────────────────
/// Launch a coding session. When [project] is non-null this launches INSIDE
/// that project (POST /project/<id>/session): the worktree toggle is dropped
/// (project sessions inherit the project's repo) and the working directory
/// defaults to the project's repo_path.
class _LaunchSheet extends StatefulWidget {
  const _LaunchSheet({required this.controller, this.project});
  final CodingSessionsController controller;
  final CodingProject? project;

  @override
  State<_LaunchSheet> createState() => _LaunchSheetState();
}

class _LaunchSheetState extends State<_LaunchSheet> {
  late final _cwd =
      TextEditingController(text: widget.project?.repoPath ?? '');
  final _title = TextEditingController();
  final _model = TextEditingController();
  final _prompt = TextEditingController();
  final _syncPath = TextEditingController();

  String _host = 'server';
  bool _worktree = false;
  bool _skipPerms = false;
  bool _sync = false;
  String? _syncDevice; // selected device id (null = none chosen)

  bool get _inProject => widget.project != null;

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
    // In-project launches may leave cwd blank (server defaults to repo_path).
    if (!_inProject && cwd.isEmpty) {
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
    final CodingSession? session;
    if (_inProject) {
      session = await widget.controller.launchInProject(
        widget.project!.id,
        cwd: cwd.isEmpty ? null : cwd,
        title: _title.text.trim(),
        prompt: prompt,
        model: _model.text.trim(),
        host: _host,
        skipPermissions: _skipPerms,
        sync: sync,
      );
    } else {
      session = await widget.controller.launch(
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
    }
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
              Text(
                _inProject
                    ? 'New session in “${widget.project!.name}”'
                    : 'Launch coding session',
                style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              _FieldLabel(_inProject
                  ? 'Working directory (blank = project repo)'
                  : 'Working directory'),
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
              if (!_inProject)
                _Toggle(
                  value: _worktree,
                  onChanged: (v) => setState(() => _worktree = v),
                  title: 'Run in an isolated git worktree',
                  subtitle:
                      'Branches a fresh worktree from the directory above.',
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

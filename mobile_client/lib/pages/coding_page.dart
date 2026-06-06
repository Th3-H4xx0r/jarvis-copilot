import 'dart:ui';

import 'package:flutter/material.dart';

import '../coding/coding_controller.dart';
import '../coding/coding_models.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

/// Native Coding tab — a control plane for tmux-backed Claude Code coding
/// sessions (the server's `coding_sessions` toolset). Lists sessions,
/// drills into one (status + subagents + a message composer + stop), and
/// launches new ones from a sheet.
///
/// MVP: no live terminal here. The session detail shows status + spawned
/// subagents and lets you type follow-ups, but the scrolling pane stays on
/// the host.
// TODO: live terminal via SSE/tmux-attach — stream the tmux pane (or a
// transcript SSE feed) into a scrollback view in the detail panel.
class CodingPage extends StatefulWidget {
  const CodingPage({super.key});

  @override
  State<CodingPage> createState() => _CodingPageState();
}

class _CodingPageState extends State<CodingPage> {
  late final CodingSessionsController _c = CodingSessionsController(app.api);
  final _composer = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.loadSessions());
  }

  @override
  void dispose() {
    _c.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty || _c.sending) return;
    _composer.clear();
    _c.send(text);
    FocusScope.of(context).unfocus();
  }

  Future<void> _openLaunchSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LaunchSheet(controller: _c),
    );
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
    return Column(
      children: [
        // Header: back + title + status pill
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
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (_c.error != null) ...[
                _InlineError(message: _c.error!),
                const SizedBox(height: 12),
              ],
              _MetaCard(session: s),
              const SizedBox(height: 16),
              _SubagentsSection(
                subagents: _c.subagents,
                loading: _c.detailLoading && _c.subagents.isEmpty,
              ),
              const SizedBox(height: 16),
              // TODO: live terminal via SSE/tmux-attach goes here.
              GlassButton(
                label: 'Stop session',
                icon: Icons.stop_rounded,
                ghost: true,
                full: true,
                onPressed: (s != null && s.isLive) ? _c.stop : null,
              ),
            ],
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
}

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

// ── Detail: metadata card ───────────────────────────────────────
class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.session});
  final CodingSession? session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const SizedBox.shrink();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Host', s.host),
          _kv('Branch', s.branch),
          _kv('Source', s.source),
          _kv('Claude session', s.claudeSessionId),
          _kv('Directory', s.cwd, last: true),
        ],
      ),
    );
  }

  Widget _kv(String label, String? value, {bool last = false}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(color: JcTheme.muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              v,
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

// ── Detail: subagents ───────────────────────────────────────────
class _SubagentsSection extends StatelessWidget {
  const _SubagentsSection({required this.subagents, required this.loading});

  final List<CodingSubagent> subagents;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        glassSectionLabel('Subagents'),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (subagents.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              'No subagents spawned yet.',
              style: TextStyle(color: JcTheme.muted, fontSize: 13),
            ),
          )
        else
          GlassGroup(
            children: [
              for (var i = 0; i < subagents.length; i++)
                _SubagentRow(
                  subagent: subagents[i],
                  last: i == subagents.length - 1,
                ),
            ],
          ),
      ],
    );
  }
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({required this.subagent, required this.last});

  final CodingSubagent subagent;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final done = subagent.isCompleted;
    final color = done ? JcTheme.success : JcTheme.primaryBlue;
    return Column(
      children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.10),
              border: Border.all(color: color.withValues(alpha: 0.30)),
            ),
            child: Icon(
              done ? Icons.check_rounded : Icons.hourglass_top_rounded,
              size: 20,
              color: color,
            ),
          ),
          title: Text(
            subagent.displayLabel,
            style: const TextStyle(
              color: JcTheme.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: subagent.description.isEmpty
              ? null
              : Text(
                  subagent.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
          trailing: Text(
            subagent.status,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
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
  final _prompt = TextEditingController();
  String _model = 'opus';
  bool _worktree = false;

  static const _models = ['opus', 'sonnet', 'haiku'];

  @override
  void dispose() {
    _cwd.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _launch() async {
    final cwd = _cwd.text.trim();
    if (cwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A project directory is required')),
      );
      return;
    }
    final nav = Navigator.of(context);
    final session = await widget.controller.launch(
      cwd: cwd,
      repoPath: _worktree ? cwd : null,
      worktree: _worktree,
      prompt: _prompt.text,
      model: _model,
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: JcTheme.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Launch coding session',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Project directory'),
              TextField(
                controller: _cwd,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '/abs/path/to/repo',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Initial prompt (optional)'),
              TextField(
                controller: _prompt,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(color: JcTheme.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'What should the session work on?',
                ),
              ),
              const SizedBox(height: 14),
              const _FieldLabel('Model'),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in _models)
                    ChoiceChip(
                      label: Text(m),
                      selected: _model == m,
                      onSelected: (_) => setState(() => _model = m),
                      selectedColor: JcTheme.primaryBlue.withValues(alpha: 0.25),
                      backgroundColor: JcTheme.glassFill,
                      labelStyle: TextStyle(
                        color: _model == m ? JcTheme.text : JcTheme.muted,
                        fontWeight: FontWeight.w600,
                      ),
                      side: const BorderSide(color: JcTheme.glassBorder),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _worktree,
                onChanged: (v) => setState(() => _worktree = v),
                activeThumbColor: JcTheme.primaryBlue,
                title: const Text(
                  'Isolate in a git worktree',
                  style: TextStyle(color: JcTheme.text, fontSize: 14),
                ),
                subtitle: const Text(
                  'Branches a fresh worktree from the directory above.',
                  style: TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
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

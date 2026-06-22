import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/crons.dart';
import '../../main.dart' as app;
import '../../services/api_client.dart' show apiErrorMessage;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';
import '../../widgets/picker.dart';
import '../../widgets/status_pill.dart';

/// Native "Tasks (cron)" screen — full parity with the web Tasks panel.
///
/// Lists scheduled jobs as glass cards (name, schedule, status badge, next/last
/// run), lets you create/edit/delete jobs, run/pause/resume them, and inspect
/// per-job run history (each run lazy-loads its output when expanded).
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  late final CronsApi _api = CronsApi(app.api);
  final AsyncViewController _ctrl = AsyncViewController();

  /// Auto-refresh poll: runs only while at least one job is actively running,
  /// so the running indicator + status stay live without constant polling.
  Timer? _poll;

  /// Job ids whose run() call is in flight — drives a spinner on that card's
  /// Run button for immediate feedback before the status flips to RUNNING.
  final Set<String> _startingRuns = {};

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Start/stop the live poll based on whether anything is running.
  void _syncPoll(bool anyRunning) {
    if (anyRunning) {
      _poll ??= Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted) _ctrl.refresh();
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Seed for the skills chip picker — the union of skills across all loaded
  /// jobs, so editing an existing job keeps its skills selectable.
  final Set<String> _knownSkills = {};

  void _harvestSkills(List<Map<String, dynamic>> jobs) {
    for (final j in jobs) {
      final s = j['skills'];
      if (s is List) {
        for (final v in s) {
          final name = v.toString().trim();
          if (name.isNotEmpty) _knownSkills.add(name);
        }
      }
    }
  }

  // ── Mutations ──────────────────────────────────────────────────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runAction(Future<void> Function() op, String okMsg) async {
    try {
      await op();
      if (!mounted) return;
      _snack(okMsg);
      await _ctrl.refresh();
    } catch (e) {
      _snack(apiErrorMessage(e));
    }
  }

  /// Run a job straight from its card, with a spinner on the Run button while
  /// the request is in flight and the live poll kicked on immediately.
  Future<void> _runJob(Map<String, dynamic> job) async {
    final id = cronJobId(job);
    setState(() => _startingRuns.add(id));
    _syncPoll(true);
    try {
      await _api.run(id);
      _snack('Run started');
    } catch (e) {
      _snack(apiErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() => _startingRuns.remove(id));
        await _ctrl.refresh();
      }
    }
  }

  // ── Create / edit form ─────────────────────────────────────────────────

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final editing = existing != null;
    final prompt =
        TextEditingController(text: (existing?['prompt'] ?? '').toString());
    final schedule =
        TextEditingController(text: editing ? cronSchedule(existing) : '');
    final name =
        TextEditingController(text: (existing?['name'] ?? '').toString());
    final model =
        TextEditingController(text: (existing?['model'] ?? '').toString());
    final profile =
        TextEditingController(text: (existing?['profile'] ?? '').toString());

    var deliver = (existing?['deliver'] ?? 'local').toString();
    if (deliver.isEmpty) deliver = 'local';
    final deliverOptions = <String>['local', 'origin', 'telegram', 'discord', 'slack'];
    if (deliver.isNotEmpty && !deliverOptions.contains(deliver)) {
      deliverOptions.add(deliver);
    }

    var toast = existing == null
        ? true
        : (existing['toast_notifications'] is bool
            ? existing['toast_notifications'] as bool
            : true);

    final selectedSkills = <String>{};
    if (existing?['skills'] is List) {
      for (final v in (existing!['skills'] as List)) {
        final s = v.toString().trim();
        if (s.isNotEmpty) selectedSkills.add(s);
      }
    }
    final allSkills = (<String>{..._knownSkills, ...selectedSkills}.toList()
      ..sort());

    await showFormSheet(
      context: context,
      title: editing ? 'Edit task' : 'New task',
      fields: [
        StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormTextField(
                label: 'Prompt',
                controller: prompt,
                maxLines: 4,
                hint: 'What should the agent do?',
              ),
              FormTextField(
                label: 'Schedule',
                controller: schedule,
                hint: 'e.g. every day at 9am, or */15 * * * *',
              ),
              FormTextField(
                label: 'Name (optional)',
                controller: name,
              ),
              FormDropdown<String>(
                label: 'Deliver',
                sheetTitle: 'Deliver results to',
                value: deliverOptions.contains(deliver)
                    ? deliver
                    : deliverOptions.first,
                options: deliverOptions
                    .map((d) => PickerOption(d, _deliverLabel(d),
                        icon: _deliverIcon(d)))
                    .toList(),
                onChanged: (v) => setSheet(() => deliver = v ?? deliver),
              ),
              if (allSkills.isNotEmpty)
                FormChipMulti(
                  label: 'Skills',
                  all: allSkills,
                  selected: selectedSkills,
                  onChanged: (s) => setSheet(() {
                    selectedSkills
                      ..clear()
                      ..addAll(s);
                  }),
                ),
              FormTextField(
                label: 'Model (optional)',
                controller: model,
              ),
              FormTextField(
                label: 'Profile (optional)',
                controller: profile,
              ),
              FormToggle(
                label: 'Completion toasts',
                value: toast,
                onChanged: (v) => setSheet(() => toast = v),
              ),
            ],
          ),
        ),
      ],
      onSave: () async {
        final body = <String, dynamic>{
          'prompt': prompt.text.trim(),
          'schedule': schedule.text.trim(),
          'name': name.text.trim(),
          'deliver': deliver,
          'skills': selectedSkills.toList(),
          'model': model.text.trim(),
          'profile': profile.text.trim(),
          'toast_notifications': toast,
        };
        // Drop blank optionals so the server keeps its defaults.
        body.removeWhere((k, v) =>
            (k == 'name' || k == 'model' || k == 'profile') &&
            (v == null || (v is String && v.trim().isEmpty)));
        try {
          if (editing) {
            body['job_id'] = cronJobId(existing);
            await _api.update(body);
          } else {
            await _api.create(body);
          }
          if (mounted) await _ctrl.refresh();
          return true;
        } catch (e) {
          _snack(apiErrorMessage(e));
          return false;
        }
      },
      saveLabel: editing ? 'Save' : 'Create',
    );
  }

  // ── Detail sheet ───────────────────────────────────────────────────────

  Future<void> _confirmDelete(Map<String, dynamic> job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Delete task?',
            style: TextStyle(color: JcTheme.text)),
        content: Text(
          'This removes "${(job['name'] ?? cronJobId(job))}" permanently.',
          style: const TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _runAction(
          () => _api.delete(cronJobId(job)), 'Task deleted');
    }
  }

  void _openDetail(Map<String, dynamic> job) {
    final id = cronJobId(job);
    final statusKey = cronStatusKey(job);
    final paused = cronIsPaused(job);
    final skills = (job['skills'] is List)
        ? (job['skills'] as List).map((e) => e.toString()).join(', ')
        : '';
    final toast = job['toast_notifications'] is bool
        ? (job['toast_notifications'] as bool)
        : true;
    final prompt = (job['prompt'] ?? '').toString().trim();
    final deliver = (job['deliver'] ?? '').toString();
    final nextRun = formatCronTime(job['next_run'] ?? job['next_run_at']);
    final lastRun = formatCronTime(job['last_run'] ?? job['last_run_at']);

    // Build the 2-up info grid from the non-empty fields.
    final tiles = <Widget>[];
    void add(IconData icon, String label, String value) {
      if (value.trim().isNotEmpty) tiles.add(_InfoTile(icon, label, value));
    }
    add(Icons.schedule_rounded, 'Schedule', cronSchedule(job));
    add(Icons.arrow_forward_rounded, 'Next run', nextRun);
    add(Icons.history_rounded, 'Last run', lastRun);
    add(Icons.person_outline, 'Profile', (job['profile'] ?? '').toString());
    add(_deliverIcon(deliver), 'Deliver', _deliverLabel(deliver));
    add(Icons.memory_rounded, 'Model', (job['model'] ?? '').toString());
    add(Icons.extension_outlined, 'Skills', skills);
    add(Icons.notifications_none_rounded, 'Toasts',
        toast ? 'Enabled' : 'Disabled');
    final grid = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      grid.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 10),
              if (i + 1 < tiles.length)
                Expanded(child: tiles[i + 1])
              else
                const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ));
    }

    showDetailSheet(
      context: context,
      title: (job['name'] ?? 'Task').toString(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(
            cronStatusLabel(statusKey),
            color: cronStatusColor(statusKey),
            live: statusKey == 'running',
          ),
          const SizedBox(height: 16),
          if (prompt.isNotEmpty) ...[
            _PromptCard(prompt),
            const SizedBox(height: 18),
          ],
          const SectionHeader('Details'),
          ...grid,
          const SizedBox(height: 10),
          const SectionHeader('Run history'),
          _RunHistory(api: _api, jobId: id),
          const SizedBox(height: 20),
          _DetailActionBar(
            paused: paused,
            onRun: () {
              Navigator.of(context).pop();
              _runAction(() => _api.run(id), 'Run started');
            },
            onPauseResume: () {
              Navigator.of(context).pop();
              if (paused) {
                _runAction(() => _api.resume(id), 'Task resumed');
              } else {
                _runAction(() => _api.pause(id), 'Task paused');
              }
            },
            onEdit: () {
              Navigator.of(context).pop();
              _openForm(existing: job);
            },
            onDelete: () {
              Navigator.of(context).pop();
              _confirmDelete(job);
            },
          ),
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Tasks',
        trailing: GlassIconButton(
          icon: Icons.add,
          onTap: () => _openForm(),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: AsyncView<List<Map<String, dynamic>>>(
            controller: _ctrl,
            loader: () => _api.list(),
            isEmpty: (d) => d.isEmpty,
            emptyText: 'No scheduled tasks yet.',
            builder: (ctx, jobs, refresh) {
              _harvestSkills(jobs);
              final anyRunning = jobs.any((j) =>
                  cronStatusKey(j) == 'running' ||
                  _startingRuns.contains(cronJobId(j)));
              WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _syncPoll(anyRunning));
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: jobs.length,
                itemBuilder: (_, i) {
                  final job = jobs[i];
                  final id = cronJobId(job);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _JobCard(
                      job: job,
                      starting: _startingRuns.contains(id),
                      onTap: () => _openDetail(job),
                      onRun: () => _runJob(job),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

String _deliverLabel(String d) {
  switch (d) {
    case 'local':
      return 'In-app only';
    case 'origin':
      return 'Originating chat';
    case 'telegram':
      return 'Telegram';
    case 'discord':
      return 'Discord';
    case 'slack':
      return 'Slack';
    default:
      return d.isEmpty ? '—' : '${d[0].toUpperCase()}${d.substring(1)}';
  }
}

IconData _deliverIcon(String d) {
  switch (d) {
    case 'local':
      return Icons.phone_iphone_rounded;
    case 'origin':
      return Icons.reply_rounded;
    case 'telegram':
      return Icons.send_rounded;
    case 'discord':
      return Icons.forum_rounded;
    case 'slack':
      return Icons.tag_rounded;
    default:
      return Icons.notifications_none_rounded;
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.onTap,
    required this.onRun,
    this.starting = false,
  });
  final Map<String, dynamic> job;
  final VoidCallback onTap;
  final VoidCallback onRun;
  final bool starting;

  @override
  Widget build(BuildContext context) {
    final statusKey = cronStatusKey(job);
    final running = statusKey == 'running' || starting;
    final color = running ? JcTheme.primaryBlue : cronStatusColor(statusKey);
    final schedule = cronSchedule(job);
    final next = formatCronTime(job['next_run'] ?? job['next_run_at']);
    final last = formatCronTime(job['last_run'] ?? job['last_run_at']);
    return GlassCard(
      blur: false,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(16, 15, 12, 15),
      borderColor: running
          ? JcTheme.primaryBlue.withValues(alpha: 0.5)
          : JcTheme.glassBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  (job['name'] ?? '(unnamed)').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: JcTheme.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              StatusPill(
                starting ? 'STARTING' : cronStatusLabel(statusKey),
                color: color,
                live: running,
                dense: true,
              ),
              const SizedBox(width: 10),
              _RunButton(running: running, starting: starting, onRun: onRun),
            ],
          ),
          if (schedule.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.schedule_rounded,
                    size: 14, color: JcTheme.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(schedule,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: JcTheme.muted, fontSize: 13)),
                ),
              ],
            ),
          ],
          if (next.isNotEmpty || last.isNotEmpty) ...[
            const SizedBox(height: 7),
            Row(
              children: [
                if (next.isNotEmpty)
                  _MetaChip(Icons.arrow_forward_rounded, 'Next', next),
                if (next.isNotEmpty && last.isNotEmpty)
                  const SizedBox(width: 14),
                if (last.isNotEmpty)
                  _MetaChip(Icons.history_rounded, 'Last', last),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A small "label value" meta with a leading icon (Next/Last run).
class _MetaChip extends StatelessWidget {
  const _MetaChip(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: JcTheme.muted.withValues(alpha: 0.8)),
        const SizedBox(width: 4),
        Text('$label ',
            style: TextStyle(
                color: JcTheme.muted.withValues(alpha: 0.7), fontSize: 12)),
        Text(value,
            style: const TextStyle(
                color: JcTheme.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// A compact, restrained Run control — a 36px glass circle with an accent
/// play glyph. Spins while starting; shows a muted refresh glyph while running.
class _RunButton extends StatelessWidget {
  const _RunButton({
    required this.running,
    required this.starting,
    required this.onRun,
  });
  final bool running;
  final bool starting;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final active = running || starting;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: active ? null : onRun,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? JcTheme.glassFill
                : JcTheme.primaryBlue.withValues(alpha: 0.16),
            border: Border.all(
              color: active
                  ? JcTheme.glassBorder
                  : JcTheme.primaryBlue.withValues(alpha: 0.5),
            ),
          ),
          child: starting
              ? const Padding(
                  padding: EdgeInsets.all(9),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: JcTheme.primaryBlue),
                )
              : Icon(
                  running ? Icons.autorenew_rounded : Icons.play_arrow_rounded,
                  color: running ? JcTheme.muted : JcTheme.primaryBlue,
                  size: 20,
                ),
        ),
      ),
    );
  }
}

/// A highlighted card showing the task's prompt (its instruction).
class _PromptCard extends StatelessWidget {
  const _PromptCard(this.prompt);
  final String prompt;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          JcTheme.accent.withValues(alpha: 0.12),
          JcTheme.cyan.withValues(alpha: 0.04),
        ]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JcTheme.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.bolt_rounded, size: 14, color: JcTheme.accent),
            SizedBox(width: 6),
            Text('PROMPT',
                style: TextStyle(
                    color: JcTheme.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
          ]),
          const SizedBox(height: 8),
          Text(prompt,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14, height: 1.4)),
        ],
      ),
    );
  }
}

/// A compact labelled metric tile for the detail info grid.
class _InfoTile extends StatelessWidget {
  const _InfoTile(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: JcTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 13, color: JcTheme.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: JcTheme.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// The detail sheet's action bar — a clean 2×2 grid of equal buttons.
class _DetailActionBar extends StatelessWidget {
  const _DetailActionBar({
    required this.paused,
    required this.onRun,
    required this.onPauseResume,
    required this.onEdit,
    required this.onDelete,
  });
  final bool paused;
  final VoidCallback onRun;
  final VoidCallback onPauseResume;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(children: [
          Expanded(
            child: _ActionButton(
                icon: Icons.play_arrow_rounded,
                label: 'Run now',
                primary: true,
                onTap: onRun),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionButton(
                icon: paused ? Icons.play_circle_outline : Icons.pause_rounded,
                label: paused ? 'Resume' : 'Pause',
                onTap: onPauseResume),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _ActionButton(
                icon: Icons.edit_outlined, label: 'Edit', onTap: onEdit),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionButton(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                danger: true,
                onTap: onDelete),
          ),
        ]),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? JcTheme.danger : (primary ? Colors.white : JcTheme.text);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: primary ? blueGradient() : null,
            color: primary ? null : JcTheme.glassFill,
            border: primary
                ? null
                : Border.all(
                    color: danger
                        ? JcTheme.danger.withValues(alpha: 0.45)
                        : JcTheme.glassBorder),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 7),
                Text(label,
                    style: TextStyle(
                        color: color, fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lazy run-history list. Loads the history index once, then each run's full
/// output is fetched only when its [ExpansionTile] is first expanded.
class _RunHistory extends StatefulWidget {
  const _RunHistory({required this.api, required this.jobId});
  final CronsApi api;
  final String jobId;

  @override
  State<_RunHistory> createState() => _RunHistoryState();
}

class _RunHistoryState extends State<_RunHistory> {
  late Future<List<Map<String, dynamic>>> _future;
  final Map<String, String> _outputs = {};
  final Set<String> _loadingRuns = {};

  @override
  void initState() {
    super.initState();
    _future = widget.api.history(widget.jobId);
  }

  Future<void> _loadRun(String filename) async {
    if (_outputs.containsKey(filename) || _loadingRuns.contains(filename)) {
      return;
    }
    setState(() => _loadingRuns.add(filename));
    try {
      final out = await widget.api.runOutput(widget.jobId, filename);
      if (mounted) {
        setState(() => _outputs[filename] = out);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _outputs[filename] = 'Failed to load output: $e');
      }
    } finally {
      if (mounted) setState(() => _loadingRuns.remove(filename));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snap.hasError) {
          return Text('Failed to load history: ${snap.error}',
              style: const TextStyle(color: JcTheme.danger, fontSize: 12));
        }
        final runs = snap.data ?? const [];
        if (runs.isEmpty) {
          return const Text('No runs yet.',
              style: TextStyle(color: JcTheme.muted, fontSize: 13));
        }
        return Column(
          children: [
            for (final (i, run) in runs.indexed)
              Builder(builder: (_) {
                final fn = (run['filename'] ?? '').toString();
                final key = fn.isNotEmpty ? fn : 'run_$i';
                final loading = _loadingRuns.contains(key);
                final output = _outputs[key];
                return Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding:
                        const EdgeInsets.symmetric(horizontal: 4),
                    childrenPadding:
                        const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    collapsedIconColor: JcTheme.muted,
                    iconColor: JcTheme.accent,
                    title: Text(
                      _runLabel(run),
                      style: const TextStyle(
                          color: JcTheme.text, fontSize: 13),
                    ),
                    subtitle: _runSubtitle(run) == null
                        ? null
                        : Text(_runSubtitle(run)!,
                            style: const TextStyle(
                                color: JcTheme.muted, fontSize: 11)),
                    onExpansionChanged: (open) {
                      if (open) _loadRun(key);
                    },
                    children: [
                      if (loading && output == null)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            height: 16,
                            width: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: JcTheme.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: SelectableText(
                            (output == null || output.isEmpty)
                                ? '(no output)'
                                : output,
                            style: const TextStyle(
                                color: JcTheme.text,
                                fontSize: 12,
                                height: 1.4),
                          ),
                        ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  String _runLabel(Map<String, dynamic> run) {
    final fn = (run['filename'] ?? '').toString();
    if (fn.isNotEmpty) {
      return fn.replaceAll('.md', '').replaceAll('_', ' ');
    }
    final ts = (run['ts'] ?? run['modified'] ?? '').toString();
    return ts.isEmpty ? 'Run' : ts;
  }

  String? _runSubtitle(Map<String, dynamic> run) {
    final size = run['size'];
    if (size is num) return '${(size / 1024).toStringAsFixed(1)} KB';
    return null;
  }
}

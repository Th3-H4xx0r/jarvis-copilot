import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/kanban.dart';
import '../../api/profiles.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';
import '../../widgets/picker.dart';

/// Native Kanban screen at parity with the web kanban panel, rendered as a
/// status-grouped LIST (one section per column) rather than a horizontal
/// board — the phone-friendly shape.
///
/// Live updates arrive over the bridge's SSE feed (`events()`); if that
/// stream errors or closes we fall back to a 30s refresh poll. Both are torn
/// down in [dispose].
class KanbanPage extends StatefulWidget {
  const KanbanPage({super.key});

  @override
  State<KanbanPage> createState() => _KanbanPageState();
}

class _KanbanPageState extends State<KanbanPage> {
  final KanbanApi _api = KanbanApi(app.api);
  final AsyncViewController _ctrl = AsyncViewController();

  StreamSubscription<Map<String, dynamic>>? _sse;
  Timer? _poll;

  /// Active board slug (null ⇒ the server's current board). We keep a copy of
  /// the boards list + current slug for the switcher.
  String? _boardSlug;
  List<Map<String, dynamic>> _boards = const [];
  String? _currentSlug;

  /// Column filter: null ⇒ "All", otherwise a single column.
  String? _columnFilter;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void dispose() {
    _sse?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  // ── live updates ──────────────────────────────────────────────────────

  void _subscribe() {
    _sse?.cancel();
    _sse = _api.events().listen(
      (_) {
        if (mounted) _ctrl.refresh();
      },
      onError: (_) => _startPolling(),
      onDone: _startPolling,
      cancelOnError: true,
    );
  }

  void _startPolling() {
    if (!mounted) return; // a stream error during dispose must not start a timer
    if (_poll != null) return; // already polling
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _ctrl.refresh();
    });
  }

  // ── data loading ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _load() async {
    // Refresh the board switcher alongside the board itself.
    try {
      final boards = await _api.boards();
      String? current;
      for (final b in boards) {
        if (b['is_current'] == true) current = '${b['slug']}';
      }
      if (mounted) {
        setState(() {
          _boards = boards;
          _currentSlug = current;
        });
      }
    } catch (_) {
      // Switcher is best-effort; the board load below is what matters.
    }
    return _api.board(slug: _boardSlug);
  }

  // ── mutations ─────────────────────────────────────────────────────────

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$e'), backgroundColor: JcTheme.danger),
    );
  }

  Future<void> _switchBoard(String slug) async {
    try {
      await _api.switchBoard(slug);
      if (!mounted) return;
      setState(() => _boardSlug = null); // current pointer now points at slug
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  /// Run the dispatcher: claims ready+assigned tasks and spawns workers. The
  /// global action; assigned tasks (incl. the one being viewed) get picked up.
  Future<void> _runDispatcher() async {
    try {
      final res = await _api.dispatch(slug: _boardSlug);
      if (!mounted) return;
      final n = res['spawned'] ?? res['claimed'] ?? res['count'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n != null
            ? 'Dispatcher ran — $n worker${n == 1 ? '' : 's'} started'
            : 'Dispatcher ran'),
        backgroundColor: JcTheme.surfaceAlt,
      ));
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  /// Per-task run: the dispatcher only claims ready+assigned tasks, so guide
  /// the user to assign first, then run.
  Future<void> _runTask(Map<String, dynamic> task) async {
    final assignee = '${task['assignee'] ?? ''}'.trim();
    if (assignee.isEmpty) {
      _showError('Assign a profile to this task first (Edit → Assignee), then Run.');
      return;
    }
    await _runDispatcher();
  }

  Future<void> _openBoardPicker() async {
    final options = [
      for (final b in _boards)
        PickerOption<String>(
          '${b['slug']}',
          '${b['name'] ?? b['title'] ?? b['slug']}',
          subtitle: b['total'] != null ? '${b['total']} task(s)' : null,
          icon: Icons.view_kanban_rounded,
        ),
    ];
    if (options.isEmpty) return;
    final picked = await showPickerSheet<String>(
      context: context,
      title: 'Switch board',
      options: options,
      selected: _currentSlug,
    );
    if (picked != null && picked != _currentSlug) _switchBoard(picked);
  }

  Future<void> _openBoardActions(Map<String, dynamic>? current) async {
    final action = await showPickerSheet<String>(
      context: context,
      title: 'Board',
      options: const [
        PickerOption('create', 'New board', icon: Icons.add_rounded),
        PickerOption('rename', 'Rename board', icon: Icons.edit_outlined),
        PickerOption('archive', 'Archive board', icon: Icons.archive_outlined),
      ],
    );
    switch (action) {
      case 'create':
        _createBoard();
        break;
      case 'rename':
        if (current != null) _renameBoard(current);
        break;
      case 'archive':
        if (current != null) _archiveBoard(current);
        break;
    }
  }

  Future<void> _createBoard() async {
    final titleC = TextEditingController();
    final descC = TextEditingController();
    final ok = await showFormSheet(
      context: context,
      title: 'New board',
      fields: [
        FormTextField(label: 'Title', controller: titleC, hint: 'Board name'),
        FormTextField(
            label: 'Description', controller: descC, maxLines: 3, hint: 'Optional'),
      ],
      onSave: () async {
        if (titleC.text.trim().isEmpty) {
          _showError('Title is required');
          return false;
        }
        try {
          await _api.createBoard(titleC.text.trim(), descC.text.trim());
          return true;
        } catch (e) {
          _showError(e);
          return false;
        }
      },
    );
    if (ok == true) {
      // The bridge created the board with `switch: true`, so it's now the
      // server's current board. Drop any local slug override so the UI follows
      // the server's now-current board.
      if (mounted) setState(() => _boardSlug = null);
      await _ctrl.refresh();
    }
  }

  Future<void> _renameBoard(Map<String, dynamic> board) async {
    final slug = '${board['slug']}';
    final nameC =
        TextEditingController(text: '${board['name'] ?? board['title'] ?? slug}');
    final descC = TextEditingController(text: '${board['description'] ?? ''}');
    final ok = await showFormSheet(
      context: context,
      title: 'Rename board',
      fields: [
        FormTextField(label: 'Name', controller: nameC),
        FormTextField(label: 'Description', controller: descC, maxLines: 3),
      ],
      onSave: () async {
        try {
          await _api.renameBoard(slug, {
            'name': nameC.text.trim(),
            'description': descC.text.trim(),
          });
          return true;
        } catch (e) {
          _showError(e);
          return false;
        }
      },
    );
    if (ok == true) await _ctrl.refresh();
  }

  Future<void> _archiveBoard(Map<String, dynamic> board) async {
    final slug = '${board['slug']}';
    final confirmed = await _confirm(
      'Archive board?',
      'Archive "${board['name'] ?? slug}"? Its tasks stay on disk but the board '
          'is hidden from the switcher.',
    );
    if (confirmed != true) return;
    try {
      await _api.archiveBoard(slug);
      if (!mounted) return;
      setState(() => _boardSlug = null);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<bool?> _confirm(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: Text(title, style: const TextStyle(color: JcTheme.text)),
        content: Text(message, style: const TextStyle(color: JcTheme.muted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm',
                style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _createTask() async {
    final titleC = TextEditingController();
    final descC = TextEditingController();
    final assigneeC = TextEditingController();
    final priorityC = TextEditingController(text: '0');
    String column = 'todo';
    final ok = await showFormSheet(
      context: context,
      title: 'New task',
      fields: [
        FormTextField(label: 'Title', controller: titleC, hint: 'What needs doing'),
        FormTextField(
            label: 'Description', controller: descC, maxLines: 4, hint: 'Optional'),
        StatefulBuilder(
          builder: (ctx, setLocal) => FormDropdown<String>(
            label: 'Column',
            value: column,
            // 'running' is excluded as a create target — the bridge rejects a
            // direct status write to 'running' with HTTP 400.
            options: [
              for (final c in kanbanColumns.where((c) => c != 'running'))
                PickerOption(c, _columnLabel(c), icon: _columnIcon(c)),
            ],
            onChanged: (v) => setLocal(() => column = v ?? 'todo'),
          ),
        ),
        _AssigneeField(controller: assigneeC),
        FormTextField(
            label: 'Priority',
            controller: priorityC,
            keyboardType: TextInputType.number,
            hint: '0'),
      ],
      onSave: () async {
        if (titleC.text.trim().isEmpty) {
          _showError('Title is required');
          return false;
        }
        try {
          await _api.createTask({
            'title': titleC.text.trim(),
            'body': descC.text.trim(),
            'status': column,
            if (assigneeC.text.trim().isNotEmpty)
              'assignee': assigneeC.text.trim(),
            'priority': int.tryParse(priorityC.text.trim()) ?? 0,
          }, board: _boardSlug);
          return true;
        } catch (e) {
          _showError(e);
          return false;
        }
      },
    );
    if (ok == true) await _ctrl.refresh();
  }

  Future<void> _editTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final titleC = TextEditingController(text: '${task['title'] ?? ''}');
    final descC = TextEditingController(text: '${task['body'] ?? task['description'] ?? ''}');
    final assigneeC = TextEditingController(text: '${task['assignee'] ?? ''}');
    final priorityC =
        TextEditingController(text: '${task['priority'] ?? 0}');
    final ok = await showFormSheet(
      context: context,
      title: 'Edit task',
      fields: [
        FormTextField(label: 'Title', controller: titleC),
        FormTextField(label: 'Description', controller: descC, maxLines: 4),
        _AssigneeField(controller: assigneeC),
        FormTextField(
            label: 'Priority',
            controller: priorityC,
            keyboardType: TextInputType.number),
      ],
      onSave: () async {
        if (titleC.text.trim().isEmpty) {
          _showError('Title is required');
          return false;
        }
        try {
          await _api.patchTask(id, {
            'title': titleC.text.trim(),
            'body': descC.text.trim(),
            'assignee': assigneeC.text.trim(),
            'priority': int.tryParse(priorityC.text.trim()) ?? 0,
          }, board: _boardSlug);
          return true;
        } catch (e) {
          _showError(e);
          return false;
        }
      },
    );
    if (ok == true) await _ctrl.refresh();
  }

  Future<void> _moveTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final current = kanbanTaskColumn(task);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: JcTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('Move to column',
                style: TextStyle(
                    color: JcTheme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            // 'running' is excluded as a manual move target — the bridge
            // rejects a direct PATCH status='running' with HTTP 400 (entering
            // 'running' is the dispatcher/claim path's job).
            for (final c in kanbanColumns.where((c) => c != 'running'))
              ListTile(
                title: Text(_columnLabel(c),
                    style: const TextStyle(color: JcTheme.text)),
                trailing: c == current
                    ? const Icon(Icons.check, color: JcTheme.accent)
                    : null,
                onTap: () => Navigator.of(ctx).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await _api.patchTask(id, {'status': picked}, board: _boardSlug);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _blockTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final reason = await _promptText('Block task', 'Reason', hint: 'Why blocked?');
    if (reason == null) return;
    try {
      await _api.block(id, reason, board: _boardSlug);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _unblockTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    try {
      await _api.unblock(id, board: _boardSlug);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _commentTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final text = await _promptText('Add comment', 'Comment', hint: 'Your note');
    if (text == null || text.trim().isEmpty) return;
    try {
      await _api.comment(id, text.trim(), board: _boardSlug);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _deleteTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final confirmed = await _confirm(
        'Delete task?', 'Delete "${task['title'] ?? id}"? This cannot be undone.');
    if (confirmed != true) return;
    try {
      await _api.deleteTask(id, board: _boardSlug);
      await _ctrl.refresh();
    } catch (e) {
      _showError(e);
    }
  }

  /// A tiny opaque single-line text dialog (block reason, comment).
  Future<String?> _promptText(String title, String label, {String? hint}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: Text(title, style: const TextStyle(color: JcTheme.text)),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          style: const TextStyle(color: JcTheme.text),
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: const Text('OK')),
        ],
      ),
    );
  }

  // ── detail sheet ──────────────────────────────────────────────────────

  Future<void> _openTask(Map<String, dynamic> task) async {
    final id = kanbanTaskId(task);
    final column = kanbanTaskColumn(task);
    await showDetailSheet<void>(
      context: context,
      title: '${task['title'] ?? id}',
      child: _TaskDetailBody(api: _api, task: task, board: _boardSlug),
      actions: [
        _SheetAction(
          icon: Icons.bolt_rounded,
          label: 'Run',
          primary: true,
          onTap: () {
            Navigator.of(context).pop();
            _runTask(task);
          },
        ),
        _SheetAction(
          icon: Icons.swap_horiz,
          label: 'Move',
          onTap: () {
            Navigator.of(context).pop();
            _moveTask(task);
          },
        ),
        if (column == 'blocked')
          _SheetAction(
            icon: Icons.lock_open,
            label: 'Unblock',
            onTap: () {
              Navigator.of(context).pop();
              _unblockTask(task);
            },
          )
        else
          _SheetAction(
            icon: Icons.block,
            label: 'Block',
            onTap: () {
              Navigator.of(context).pop();
              _blockTask(task);
            },
          ),
        _SheetAction(
          icon: Icons.comment_outlined,
          label: 'Comment',
          onTap: () {
            Navigator.of(context).pop();
            _commentTask(task);
          },
        ),
        _SheetAction(
          icon: Icons.edit_outlined,
          label: 'Edit',
          onTap: () {
            Navigator.of(context).pop();
            _editTask(task);
          },
        ),
        _SheetAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          danger: true,
          onTap: () {
            Navigator.of(context).pop();
            _deleteTask(task);
          },
        ),
      ],
    );
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Kanban',
        trailing: GlassIconButton(icon: Icons.add, onTap: _createTask),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              _boardSwitcher(),
              _filterBar(),
              Expanded(
                child: AsyncView<Map<String, dynamic>>(
                  controller: _ctrl,
                  loader: _load,
                  isEmpty: (board) => kanbanFlattenTasks(board).isEmpty,
                  emptyText: 'No tasks on this board yet.\nTap + to add one.',
                  builder: (ctx, board, refresh) => _boardList(board),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boardSwitcher() {
    final current =
        _currentSlug == null ? null : _boardForSlug(_currentSlug!);
    final label = current?['name']?.toString() ??
        current?['title']?.toString() ??
        _currentSlug ??
        'Board';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              child: InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: _openBoardPicker,
                child: GradientBorder(
                  radius: 14,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Row(
                      children: [
                        const Icon(Icons.view_kanban_rounded,
                            size: 18, color: JcTheme.cyan),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: JcTheme.text,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const Icon(Icons.expand_more_rounded,
                            color: JcTheme.muted, size: 22),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _HeaderActionButton(
            icon: Icons.bolt_rounded,
            tint: JcTheme.primaryBlue,
            onTap: _runDispatcher,
          ),
          const SizedBox(width: 8),
          _HeaderActionButton(
            icon: Icons.more_horiz_rounded,
            onTap: () => _openBoardActions(current),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      height: 50,
      alignment: Alignment.centerLeft,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Center(child: _filterChip('All', null)),
          for (final c in kanbanColumns)
            Center(child: _filterChip(_columnLabel(c), c)),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _columnFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _columnFilter = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: selected ? blueGradient() : null,
              color: selected ? null : JcTheme.glassFill,
              border: Border.all(
                  color:
                      selected ? Colors.transparent : JcTheme.glassBorder),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: JcTheme.primaryBlue.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Text(label,
                style: TextStyle(
                    color: selected ? Colors.white : JcTheme.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  Widget _boardList(Map<String, dynamic> board) {
    final tasks = kanbanFlattenTasks(board);
    final grouped = groupTasksByColumn(tasks, kanbanColumns);
    final visibleCols = _columnFilter == null
        ? kanbanColumns
        : kanbanColumns.where((c) => c == _columnFilter);

    final children = <Widget>[];
    for (final col in visibleCols) {
      final colTasks = grouped[col] ?? const [];
      if (colTasks.isEmpty) continue; // hide empty groups
      children.add(_sectionHeader(col, colTasks.length));
      for (final t in colTasks) {
        children.add(_taskTile(t));
      }
    }

    if (children.isEmpty) {
      // Filter selected a column with no tasks — keep it scrollable so
      // RefreshIndicator (in AsyncView) still works.
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
            child: Text('No tasks in this column.',
                style: TextStyle(color: JcTheme.muted)),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: children,
    );
  }

  Widget _sectionHeader(String col, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _columnColor(col),
            ),
          ),
          const SizedBox(width: 8),
          Text(_columnLabel(col).toUpperCase(),
              style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4)),
          const SizedBox(width: 6),
          Text('$count',
              style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _taskTile(Map<String, dynamic> task) {
    final assignee = '${task['assignee'] ?? ''}'.trim();
    final priority = task['priority'];
    final due = task['due'] ?? task['due_date'];
    final meta = <String>[
      if (assignee.isNotEmpty) assignee,
      if (priority != null && '$priority' != '0') 'P$priority',
      if (due != null && '$due'.trim().isNotEmpty) 'due $due',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        blur: false,
        onTap: () => _openTask(task),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${task['title'] ?? '(untitled)'}',
                style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(meta,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────

  Map<String, dynamic>? _boardForSlug(String slug) {
    for (final b in _boards) {
      if ('${b['slug']}' == slug) return b;
    }
    return null;
  }

  static String _columnLabel(String col) {
    if (col.isEmpty) return col;
    return col[0].toUpperCase() + col.substring(1);
  }

  static IconData _columnIcon(String col) {
    switch (col) {
      case 'triage':
        return Icons.inbox_rounded;
      case 'todo':
        return Icons.radio_button_unchecked;
      case 'ready':
        return Icons.play_circle_outline;
      case 'running':
        return Icons.autorenew_rounded;
      case 'blocked':
        return Icons.block;
      case 'done':
        return Icons.check_circle_outline;
      default:
        return Icons.label_outline;
    }
  }

  static Color _columnColor(String col) {
    switch (col) {
      case 'done':
        return JcTheme.success;
      case 'blocked':
        return JcTheme.danger;
      case 'running':
        return JcTheme.cyan;
      case 'ready':
        return JcTheme.accent;
      case 'triage':
        return JcTheme.accentAlt;
      default:
        return JcTheme.muted;
    }
  }
}

/// Detail sheet body: description, links, comments, and a lazily-loaded log.
class _TaskDetailBody extends StatefulWidget {
  const _TaskDetailBody({
    required this.api,
    required this.task,
    required this.board,
  });

  final KanbanApi api;
  final Map<String, dynamic> task;
  final String? board;

  @override
  State<_TaskDetailBody> createState() => _TaskDetailBodyState();
}

class _TaskDetailBodyState extends State<_TaskDetailBody> {
  bool _logLoading = false;
  String? _log;
  String? _logError;

  /// Full detail fetched from `GET /tasks/:id` — the board task only carries
  /// `comment_count` / `link_counts`, not the `comments[]` array or `links{}`
  /// object, so the Comments + Parents/Children sections need this fetch.
  bool _detailLoading = true;
  Map<String, dynamic>? _detail;

  final TextEditingController _commentC = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void dispose() {
    _commentC.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    if (!mounted) return;
    setState(() => _detailLoading = true);
    try {
      final d = await widget.api
          .taskDetail(kanbanTaskId(widget.task), board: widget.board);
      if (mounted) setState(() => _detail = d);
    } catch (_) {
      // Best-effort: fall back to whatever the board task already carried.
    } finally {
      if (mounted) setState(() => _detailLoading = false);
    }
  }

  Future<void> _postComment() async {
    final text = _commentC.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      await widget.api
          .comment(kanbanTaskId(widget.task), text, board: widget.board);
      if (!mounted) return;
      _commentC.clear();
      // Reload the detail (not just the board) so the new comment appears.
      await _loadDetail();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: JcTheme.danger),
        );
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _loadLog() async {
    setState(() {
      _logLoading = true;
      _logError = null;
    });
    try {
      final log = await widget.api
          .taskLog(kanbanTaskId(widget.task), board: widget.board);
      if (mounted) setState(() => _log = log);
    } catch (e) {
      if (mounted) setState(() => _logError = '$e');
    } finally {
      if (mounted) setState(() => _logLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final desc = '${task['body'] ?? task['description'] ?? ''}'.trim();
    final assignee = '${task['assignee'] ?? ''}'.trim();
    final priority = task['priority'];
    final due = task['due'] ?? task['due_date'];

    // Comments + links come from the full detail fetch (the board task only
    // has counts); fall back to the board task if the fetch failed.
    final detail = _detail;
    final links = detail != null ? detail['links'] : task['links'];
    final rawComments = detail != null ? detail['comments'] : task['comments'];
    final comments = (rawComments is List)
        ? rawComments.whereType<Map>().toList()
        : const <Map>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailRow('Column', kanbanTaskColumn(task)),
        if (assignee.isNotEmpty) DetailRow('Assignee', assignee),
        if (priority != null) DetailRow('Priority', '$priority'),
        if (due != null && '$due'.trim().isNotEmpty)
          DetailRow('Due', '$due'),
        if (desc.isNotEmpty) DetailRow('Description', desc),
        if (links is Map) _linksSection(links),
        if (comments.isNotEmpty) _commentsSection(comments),
        if (_detailLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          _commentComposer(),
        const SizedBox(height: 8),
        _logSection(),
      ],
    );
  }

  Widget _linksSection(Map links) {
    final parents = (links['parents'] is List)
        ? (links['parents'] as List).map((e) => '$e').toList()
        : const <String>[];
    final children = (links['children'] is List)
        ? (links['children'] as List).map((e) => '$e').toList()
        : const <String>[];
    if (parents.isEmpty && children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parents.isNotEmpty) DetailRow('Parents', parents.join(', ')),
        if (children.isNotEmpty) DetailRow('Children', children.join(', ')),
      ],
    );
  }

  Widget _commentsSection(List<Map> comments) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6, bottom: 6),
          child: Text('Comments',
              style: TextStyle(color: JcTheme.muted, fontSize: 12)),
        ),
        for (final c in comments)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${c['author'] ?? 'anon'}',
                    style: const TextStyle(
                        color: JcTheme.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text('${c['body'] ?? c['text'] ?? ''}',
                    style: const TextStyle(color: JcTheme.text, fontSize: 14)),
              ],
            ),
          ),
      ],
    );
  }

  /// Inline composer: post a comment without leaving the sheet, then reload the
  /// detail so the new comment appears immediately.
  Widget _commentComposer() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _commentC,
              minLines: 1,
              maxLines: 3,
              enabled: !_posting,
              style: const TextStyle(color: JcTheme.text, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Add a comment…',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _posting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.send, size: 20, color: JcTheme.accent),
                  onPressed: _postComment,
                ),
        ],
      ),
    );
  }

  Widget _logSection() {
    if (_log == null && !_logLoading && _logError == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _loadLog,
          icon: const Icon(Icons.article_outlined, size: 18),
          label: const Text('Load worker log'),
        ),
      );
    }
    if (_logLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_logError != null) {
      return Text('Log error: $_logError',
          style: const TextStyle(color: JcTheme.danger, fontSize: 12));
    }
    final log = _log ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Worker log',
            style: TextStyle(color: JcTheme.muted, fontSize: 12)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: JcTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: SelectableText(
            log.isEmpty ? '(empty)' : log,
            style: const TextStyle(
                color: JcTheme.text, fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

/// A small action control for the detail sheet's action row. [primary] renders
/// a filled CTA (used for Run); otherwise a frosted text button.
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    if (primary) {
      return ElevatedButton.icon(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: JcTheme.primaryBlue,
          foregroundColor: Colors.white,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }
    final color = danger ? JcTheme.danger : JcTheme.text;
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(color: color)),
    );
  }
}

/// Assignee picker sourced from the real JarvisCopilot profiles (the
/// dispatcher claims a task by activating its assignee profile). Options are
/// the profile names + Unassigned + Custom…; a typed/legacy value (e.g. a
/// removed profile) is preserved via the Custom path. Writes into [controller]
/// so the form's onSave reads it unchanged.
class _AssigneeField extends StatefulWidget {
  const _AssigneeField({required this.controller});
  final TextEditingController controller;

  @override
  State<_AssigneeField> createState() => _AssigneeFieldState();
}

class _AssigneeFieldState extends State<_AssigneeField> {
  static const _custom = '__custom__';
  static const _none = '__none__';

  late final ProfilesApi _profiles = ProfilesApi(app.api);
  List<String> _names = [];
  String _selection = _none;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await _profiles.list();
      final raw = data['profiles'];
      final names = <String>[];
      if (raw is List) {
        for (final p in raw) {
          final n = (p is Map ? (p['name'] ?? '') : p).toString().trim();
          if (n.isNotEmpty && !names.contains(n)) names.add(n);
        }
      }
      if (!mounted) return;
      final initial = widget.controller.text.trim();
      setState(() {
        _names = names;
        if (initial.isEmpty) {
          _selection = _none;
        } else if (_names.contains(initial)) {
          _selection = initial;
        } else {
          _selection = _custom; // a legacy / non-profile value — keep it
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return FormTextField(
          label: 'Assignee', controller: widget.controller, hint: 'Optional');
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FormFieldLabel('Assignee'),
            SizedBox(height: 7),
            Row(children: [
              SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Loading profiles…',
                  style: TextStyle(color: JcTheme.muted, fontSize: 13)),
            ]),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormDropdown<String>(
          label: 'Assignee',
          sheetTitle: 'Assign to profile',
          value: _selection,
          options: [
            const PickerOption(_none, 'Unassigned',
                subtitle: 'Sits in Ready — won\'t auto-run',
                icon: Icons.person_off_outlined),
            for (final n in _names)
              PickerOption(n, n,
                  subtitle: 'JarvisCopilot profile',
                  icon: Icons.account_circle_outlined),
            const PickerOption(_custom, 'Custom…',
                subtitle: 'Type a name', icon: Icons.edit_outlined),
          ],
          onChanged: (v) {
            setState(() {
              _selection = v ?? _none;
              if (_selection == _none) {
                widget.controller.text = '';
              } else if (_selection != _custom) {
                widget.controller.text = _selection;
              } else if (_names.contains(widget.controller.text.trim())) {
                widget.controller.text = '';
              }
            });
          },
        ),
        if (_selection == _custom)
          FormTextField(
              label: 'Custom assignee',
              controller: widget.controller,
              hint: 'Type a name'),
      ],
    );
  }
}

/// A 44px circular header action (dispatcher / board menu). A tinted glass
/// circle with a hairline border; [tint] colours the icon + ring.
class _HeaderActionButton extends StatelessWidget {
  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
    this.tint,
  });
  final IconData icon;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = tint ?? JcTheme.text;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.withValues(alpha: tint == null ? 0.08 : 0.16),
            border: Border.all(
                color: tint == null
                    ? JcTheme.glassBorder
                    : c.withValues(alpha: 0.5)),
          ),
          child: Icon(icon, color: c, size: 22),
        ),
      ),
    );
  }
}

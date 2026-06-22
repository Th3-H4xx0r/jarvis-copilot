import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/kanban.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';

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
    if (ok == true) await _ctrl.refresh();
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
            items: [
              for (final c in kanbanColumns)
                DropdownMenuItem(value: c, child: Text(_columnLabel(c))),
            ],
            onChanged: (v) => setLocal(() => column = v ?? 'todo'),
          ),
        ),
        FormTextField(label: 'Assignee', controller: assigneeC, hint: 'Optional'),
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
        FormTextField(label: 'Assignee', controller: assigneeC),
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
            for (final c in kanbanColumns)
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
    final label = _currentSlug == null
        ? 'Board'
        : (_boardForSlug(_currentSlug!)?['name']?.toString() ?? _currentSlug!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: GlassCard(
              blur: false,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: PopupMenuButton<String>(
                color: JcTheme.surface,
                offset: const Offset(0, 44),
                onSelected: _switchBoard,
                itemBuilder: (ctx) => [
                  for (final b in _boards)
                    PopupMenuItem<String>(
                      value: '${b['slug']}',
                      child: Row(
                        children: [
                          if (b['is_current'] == true)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(Icons.check,
                                  size: 16, color: JcTheme.accent),
                            ),
                          Expanded(
                            child: Text(
                              '${b['name'] ?? b['title'] ?? b['slug']}',
                              style: const TextStyle(color: JcTheme.text),
                            ),
                          ),
                          if (b['total'] != null)
                            Text('${b['total']}',
                                style: const TextStyle(
                                    color: JcTheme.muted, fontSize: 12)),
                        ],
                      ),
                    ),
                ],
                child: Row(
                  children: [
                    const Icon(Icons.view_kanban,
                        size: 18, color: JcTheme.primaryBlue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: JcTheme.text,
                              fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.arrow_drop_down, color: JcTheme.muted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GlassCard(
            blur: false,
            padding: EdgeInsets.zero,
            child: PopupMenuButton<String>(
              color: JcTheme.surface,
              icon: const Icon(Icons.more_vert, color: JcTheme.text),
              onSelected: (v) {
                final current = _currentSlug == null
                    ? null
                    : _boardForSlug(_currentSlug!);
                switch (v) {
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
              },
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'create', child: Text('New board…')),
                PopupMenuItem(value: 'rename', child: Text('Rename board…')),
                PopupMenuItem(value: 'archive', child: Text('Archive board')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _filterChip('All', null),
          for (final c in kanbanColumns) _filterChip(_columnLabel(c), c),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _columnFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _columnFilter = value),
        backgroundColor: JcTheme.surfaceAlt,
        selectedColor: JcTheme.accent.withValues(alpha: 0.3),
        labelStyle:
            TextStyle(color: selected ? JcTheme.text : JcTheme.muted),
        side: const BorderSide(color: JcTheme.glassBorder),
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

    final links = task['links'];
    final comments = (task['comments'] is List)
        ? (task['comments'] as List).whereType<Map>().toList()
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

/// A small frosted action button for the detail sheet's action row.
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? JcTheme.danger : JcTheme.text;
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(color: color)),
    );
  }
}

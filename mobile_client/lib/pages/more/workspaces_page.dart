import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/workspaces.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';

/// Native "Workspaces" screen — full parity with the webui Workspaces panel.
///
/// Lists the agent's registered workspace folders as a drag-to-reorder list,
/// each showing its friendly name + absolute path (and a "last used" badge on
/// the most-recent one). The `+` action adds a folder by path (with live
/// path suggestions); each row's overflow menu renames its display name or
/// removes it. All mutations go through [WorkspacesApi] and refresh the list.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({super.key});

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final WorkspacesApi _api = WorkspacesApi(app.api);

  List<Workspace> _workspaces = const [];
  String _last = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = _workspaces.isEmpty);
    try {
      final data = await _api.list();
      if (!mounted) return;
      setState(() {
        _workspaces = data.workspaces;
        _last = data.last;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addWorkspace() async {
    final controller = TextEditingController();
    final ok = await showFormSheet(
      context: context,
      title: 'Add workspace',
      saveLabel: 'Add',
      fields: [
        _PathFieldWithSuggestions(
          controller: controller,
          suggest: _api.suggest,
        ),
      ],
      onSave: () async {
        final path = controller.text.trim();
        if (path.isEmpty) {
          _snack('Enter a folder path');
          return false;
        }
        try {
          await _api.add(path);
          return true;
        } catch (e) {
          _snack('$e');
          return false;
        }
      },
    );
    controller.dispose();
    if (ok == true) await _load();
  }

  Future<void> _renameWorkspace(Workspace w) async {
    final controller = TextEditingController(text: w.name);
    final ok = await showFormSheet(
      context: context,
      title: 'Rename workspace',
      saveLabel: 'Rename',
      fields: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            w.path,
            style: const TextStyle(color: JcTheme.muted, fontSize: 12),
          ),
        ),
        FormTextField(
          label: 'Display name',
          controller: controller,
          hint: 'A friendly name for this folder',
        ),
      ],
      onSave: () async {
        final name = controller.text.trim();
        if (name.isEmpty) {
          _snack('Enter a name');
          return false;
        }
        try {
          await _api.rename(w.path, name);
          return true;
        } catch (e) {
          _snack('$e');
          return false;
        }
      },
    );
    controller.dispose();
    if (ok == true) await _load();
  }

  Future<void> _removeWorkspace(Workspace w) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Remove workspace?',
            style: TextStyle(color: JcTheme.text)),
        content: Text(
          'Remove "${w.name}" from the workspace list?\n\n'
          'This only forgets the folder here — nothing on disk is deleted.',
          style: const TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove',
                style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.remove(w.path);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    // onReorderItem already adjusts newIndex for the removed item, so we insert
    // at newIndex directly (no manual `newIndex -= 1`).
    final next = List<Workspace>.from(_workspaces);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    // Optimistically apply the new order, then persist and reconcile.
    setState(() => _workspaces = next);
    try {
      await _api.reorder(next.map((w) => w.path).toList());
    } catch (e) {
      _snack('$e');
    } finally {
      // Reconcile with the server's authoritative order / last-used badge.
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Workspaces',
        trailing: GlassIconButton(icon: Icons.add, onTap: _addWorkspace),
      ),
      body: AppBackground(
        child: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _workspaces.isEmpty) {
      return _CenterMsg(_error!, color: JcTheme.danger, onRetry: _load);
    }
    if (_workspaces.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            _CenterMsg(
              'No workspaces yet.\nTap + to add a folder for the agent to work in.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: _workspaces.length,
        onReorderItem: _onReorder,
        proxyDecorator: (child, index, animation) => Material(
          color: Colors.transparent,
          child: child,
        ),
        itemBuilder: (context, i) {
          final w = _workspaces[i];
          return _WorkspaceRow(
            key: ValueKey(w.path),
            workspace: w,
            isLast: w.path == _last && _last.isNotEmpty,
            index: i,
            onRename: () => _renameWorkspace(w),
            onRemove: () => _removeWorkspace(w),
          );
        },
      ),
    );
  }
}

/// One workspace row: a drag handle, name + "last used" badge, the path, and an
/// overflow menu (Rename / Remove).
class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({
    super.key,
    required this.workspace,
    required this.isLast,
    required this.index,
    required this.onRename,
    required this.onRemove,
  });

  final Workspace workspace;
  final bool isLast;
  final int index;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        blur: false,
        fill: JcTheme.surface,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.drag_indicator,
                    size: 20, color: JcTheme.muted),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          workspace.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: JcTheme.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isLast) ...[
                        const SizedBox(width: 8),
                        const _LastUsedBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    workspace.path,
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
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: JcTheme.muted),
              color: JcTheme.surfaceAlt,
              onSelected: (v) {
                if (v == 'rename') onRename();
                if (v == 'remove') onRemove();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'rename',
                  child: Text('Rename',
                      style: TextStyle(color: JcTheme.text)),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove',
                      style: TextStyle(color: JcTheme.danger)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LastUsedBadge extends StatelessWidget {
  const _LastUsedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: JcTheme.success.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'LAST USED',
        style: TextStyle(
          color: JcTheme.success,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// A path text field that queries [suggest] as the user types and lists the
/// returned candidates beneath it. Tapping a suggestion fills the field.
/// Robust by design: if [suggest] throws, suggestions are simply hidden.
class _PathFieldWithSuggestions extends StatefulWidget {
  const _PathFieldWithSuggestions({
    required this.controller,
    required this.suggest,
  });

  final TextEditingController controller;
  final Future<List<String>> Function(String prefix) suggest;

  @override
  State<_PathFieldWithSuggestions> createState() =>
      _PathFieldWithSuggestionsState();
}

class _PathFieldWithSuggestionsState
    extends State<_PathFieldWithSuggestions> {
  List<String> _suggestions = const [];
  Timer? _debounce;
  // Monotonic request id so a slow in-flight suggest can't overwrite a newer
  // result.
  int _reqId = 0;
  // Set while we programmatically fill the field (from a tapped suggestion) so
  // the controller listener doesn't re-query and re-open the list.
  bool _suppress = false;

  @override
  void initState() {
    super.initState();
    // FormTextField exposes no onChanged, so drive live suggestions off the
    // controller — typing in the path field queries /suggest (matching the
    // webui Workspaces panel's behaviour).
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (_suppress) return;
    _onChanged(widget.controller.text);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final prefix = value.trim();
    if (prefix.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () => _fetch(prefix));
  }

  Future<void> _fetch(String prefix) async {
    final id = ++_reqId;
    try {
      final results = await widget.suggest(prefix);
      if (!mounted || id != _reqId) return;
      setState(() => _suggestions = results);
    } catch (_) {
      if (!mounted || id != _reqId) return;
      setState(() => _suggestions = const []); // fail-soft
    }
  }

  void _pick(String path) {
    // Suppress the controller-listener re-query that setting .text would
    // otherwise trigger (it would immediately re-open the list we just closed).
    _suppress = true;
    widget.controller.text = path;
    widget.controller.selection =
        TextSelection.collapsed(offset: path.length);
    _suppress = false;
    setState(() => _suggestions = const []);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: FormTextField(
            label: 'Folder path',
            controller: widget.controller,
            hint: '/Users/you/code/project',
          ),
        ),
        TextButton.icon(
          onPressed: () => _onChanged(widget.controller.text),
          icon: const Icon(Icons.search, size: 16),
          label: const Text('Suggest paths'),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: JcTheme.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: JcTheme.glassBorder),
              itemBuilder: (_, i) {
                final s = _suggestions[i];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.folder_outlined,
                      size: 18, color: JcTheme.muted),
                  title: Text(
                    s,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: JcTheme.text, fontSize: 13),
                  ),
                  onTap: () => _pick(s),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Centered message with an optional retry button (mirrors AsyncView's empty /
/// error state so this hand-rolled screen looks consistent).
class _CenterMsg extends StatelessWidget {
  const _CenterMsg(this.text, {this.color = JcTheme.muted, this.onRetry});
  final String text;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: color)),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
}

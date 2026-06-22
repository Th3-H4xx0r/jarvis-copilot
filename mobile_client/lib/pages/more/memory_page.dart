import 'package:flutter/material.dart';

import '../../api/memory.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';

/// Native viewer/editor for the agent's long-term memory — MEMORY.md
/// ("My Notes") and USER.md ("User Profile"). Full parity with the webui
/// Memory panel: a section toggle, the selected file's content as scrollable
/// selectable text with its last-modified time, and a full-screen editor that
/// writes back via /api/memory/write.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

/// The two memory files, in the order the webui shows them.
enum _MemorySection { memory, user }

extension _MemorySectionMeta on _MemorySection {
  /// Wire value for /api/memory/write.
  String get key => this == _MemorySection.user ? 'user' : 'memory';

  String get label => this == _MemorySection.user ? 'User Profile' : 'My Notes';

  String get emptyText =>
      this == _MemorySection.user ? 'No profile yet.' : 'No notes yet.';

  /// Keys into the GET /api/memory response map.
  String get contentKey => this == _MemorySection.user ? 'user' : 'memory';
  String get mtimeKey =>
      this == _MemorySection.user ? 'user_mtime' : 'memory_mtime';
}

class _MemoryPageState extends State<MemoryPage> {
  final AsyncViewController _ctrl = AsyncViewController();
  final MemoryApi _api = MemoryApi(app.api);

  _MemorySection _section = _MemorySection.memory;
  Map<String, dynamic> _data = const {};

  String _contentFor(_MemorySection s) => (_data[s.contentKey] ?? '').toString();
  String _mtimeFor(_MemorySection s) => formatMemoryMtime(_data[s.mtimeKey]);

  Future<void> _openEditor() async {
    final initial = _contentFor(_section);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _MemoryEditorPage(
          title: _section.label,
          initialContent: initial,
          onSave: (text) => _api.write(_section.key, text),
        ),
      ),
    );
    if (saved == true) {
      await _ctrl.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Memory',
        trailing: GlassIconButton(
          icon: Icons.edit_outlined,
          onTap: _data.isEmpty ? null : _openEditor,
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: AsyncView<Map<String, dynamic>>(
            controller: _ctrl,
            loader: _api.read,
            builder: (context, data, refresh) {
              // Cache so the appBar edit button + editor read fresh content.
              _data = data;
              return _MemoryBody(
                section: _section,
                onSectionChanged: (s) => setState(() => _section = s),
                content: _contentFor(_section),
                mtime: _mtimeFor(_section),
                emptyText: _section.emptyText,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MemoryBody extends StatelessWidget {
  const _MemoryBody({
    required this.section,
    required this.onSectionChanged,
    required this.content,
    required this.mtime,
    required this.emptyText,
  });

  final _MemorySection section;
  final ValueChanged<_MemorySection> onSectionChanged;
  final String content;
  final String mtime;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SegmentedButton<_MemorySection>(
            segments: const [
              ButtonSegment(
                value: _MemorySection.memory,
                label: Text('My Notes'),
                icon: Icon(Icons.psychology_outlined),
              ),
              ButtonSegment(
                value: _MemorySection.user,
                label: Text('User Profile'),
                icon: Icon(Icons.person_outline),
              ),
            ],
            selected: {section},
            onSelectionChanged: (sel) => onSectionChanged(sel.first),
            showSelectedIcon: false,
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? JcTheme.accent.withValues(alpha: 0.30)
                      : JcTheme.surfaceAlt),
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? JcTheme.text
                      : JcTheme.muted),
              side: const WidgetStatePropertyAll(
                BorderSide(color: JcTheme.glassBorder),
              ),
            ),
          ),
        ),
        Expanded(
          child: content.trim().isEmpty
              ? _EmptyState(emptyText)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    if (mtime.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            const Icon(Icons.schedule,
                                size: 14, color: JcTheme.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Last edited $mtime',
                                style: const TextStyle(
                                    color: JcTheme.muted, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    GlassCard(
                      blur: false,
                      fill: JcTheme.surface,
                      child: SelectableText(
                        content,
                        style: const TextStyle(
                          color: JcTheme.text,
                          fontSize: 13.5,
                          height: 1.5,
                          fontFamily: 'monospace',
                          fontFamilyFallback: ['Menlo', 'Courier'],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    // Wrapped in a scroll view so the parent RefreshIndicator can still pull.
    return ListView(
      children: [
        const SizedBox(height: 100),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: JcTheme.muted),
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen multiline editor for one memory section. Pops with `true` on a
/// successful save. Guards against discarding unsaved edits via [PopScope].
class _MemoryEditorPage extends StatefulWidget {
  const _MemoryEditorPage({
    required this.title,
    required this.initialContent,
    required this.onSave,
  });

  final String title;
  final String initialContent;
  final Future<void> Function(String content) onSave;

  @override
  State<_MemoryEditorPage> createState() => _MemoryEditorPageState();
}

class _MemoryEditorPageState extends State<_MemoryEditorPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialContent);
  bool _saving = false;

  bool get _dirty => _controller.text != widget.initialContent;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Returns true if it's safe to leave (no edits, or the user confirmed).
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Discard changes?',
            style: TextStyle(color: JcTheme.text)),
        content: const Text(
          'Your edits to this section have not been saved.',
          style: TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard',
                style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmDiscard() && mounted) {
          nav.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: glassAppBar(
          context,
          title: 'Edit ${widget.title}',
          onBack: () async {
            final nav = Navigator.of(context);
            if (await _confirmDiscard() && mounted) {
              nav.pop();
            }
          },
          trailing: GlassIconButton(
            icon: Icons.check,
            color: JcTheme.success,
            onTap: _saving ? null : _save,
          ),
        ),
        body: AppBackground(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: GlassCard(
                      blur: false,
                      fill: JcTheme.surface,
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _controller,
                        onChanged: (_) => setState(() {}),
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          color: JcTheme.text,
                          fontSize: 13.5,
                          height: 1.5,
                          fontFamily: 'monospace',
                          fontFamilyFallback: ['Menlo', 'Courier'],
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          hintText: 'Write Markdown here…',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassButton(
                    label: _saving ? 'Saving…' : 'Save',
                    icon: Icons.save_outlined,
                    full: true,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

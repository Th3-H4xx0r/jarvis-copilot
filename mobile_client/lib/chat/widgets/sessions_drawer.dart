import 'package:flutter/material.dart';

import '../../theme.dart';
import '../chat_controller.dart';
import '../chat_models.dart';

/// Sidebar drawer listing the user's chat sessions — the mobile
/// equivalent of the webui session sidebar. New chat at top, then the
/// sessions ordered by recency.
class SessionsDrawer extends StatelessWidget {
  const SessionsDrawer({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: JcTheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Text(
                    'Chats',
                    style: TextStyle(
                      color: JcTheme.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'New chat',
                    icon: const Icon(Icons.add, color: JcTheme.accent),
                    onPressed: () {
                      controller.startNewSession();
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  if (controller.sessionsLoading && controller.sessions.isEmpty) {
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  if (controller.sessions.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No chats yet.\nStart a conversation below.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: JcTheme.muted),
                        ),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: controller.loadSessions,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: controller.sessions.length,
                      itemBuilder: (context, i) {
                        final s = controller.sessions[i];
                        final active = s.id == controller.sessionId;
                        return _SessionTile(
                          session: s,
                          active: active,
                          onTap: () {
                            Navigator.of(context).pop();
                            if (!active) controller.openSession(s.id);
                          },
                          onRename: () => _rename(context, s),
                          onDelete: () => _confirmDelete(context, s),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, ChatSessionSummary s) async {
    final ctrl = TextEditingController(text: s.displayTitle);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Rename chat', style: TextStyle(color: JcTheme.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: JcTheme.text),
          decoration: const InputDecoration(hintText: 'Chat title'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (title != null && title.isNotEmpty && title != s.title) {
      await controller.renameSession(s.id, title);
    }
  }

  Future<void> _confirmDelete(BuildContext context, ChatSessionSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Delete chat', style: TextStyle(color: JcTheme.text)),
        content: Text(
          'Delete "${s.displayTitle}"? This cannot be undone.',
          style: const TextStyle(color: JcTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: JcTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await controller.deleteSession(s.id);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete: $e')),
          );
        }
      }
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.active,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final ChatSessionSummary session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        dense: true,
        // Use ListTile's own tileColor (not an outer DecoratedBox) so the
        // background and ink splashes paint on the right Material layer.
        tileColor: active ? JcTheme.accent.withValues(alpha: 0.12) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          session.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? JcTheme.accent : JcTheme.text,
            fontSize: 13.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: session.isStreaming
            ? const Text('streaming…',
                style: TextStyle(color: JcTheme.blue, fontSize: 11))
            : null,
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz, size: 18, color: JcTheme.muted),
          color: JcTheme.surfaceAlt,
          onSelected: (v) {
            if (v == 'rename') onRename();
            if (v == 'delete') onDelete();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

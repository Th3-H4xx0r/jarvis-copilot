import 'package:flutter/material.dart';

import '../../api/todos.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';

/// Read-only mirror of the webui "Todos" panel: the active chat session's
/// current todo list, derived from its message history (there is no todos API).
/// Each row shows a status icon + colour, the todo text (struck through when
/// completed/cancelled), and a small status label. Pull-to-refresh re-fetches.
class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  final AsyncViewController _ctrl = AsyncViewController();
  final TodosApi _api = TodosApi(app.api);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Todos',
        trailing: GlassIconButton(
          icon: Icons.refresh_rounded,
          onTap: () => _ctrl.refresh(),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: AsyncView<List<Map<String, dynamic>>>(
            controller: _ctrl,
            loader: _api.currentSession,
            isEmpty: (todos) => todos.isEmpty,
            emptyText: 'No active todo list.',
            builder: (context, todos, refresh) {
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: todos.length,
                itemBuilder: (_, i) => _TodoRow(todo: todos[i]),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Visual treatment per todo status — mirrors panels.js loadTodos.
class _TodoStatusStyle {
  const _TodoStatusStyle(this.icon, this.color, this.strikethrough);
  final IconData icon;
  final Color color;
  final bool strikethrough;

  static _TodoStatusStyle of(String status) {
    switch (status) {
      case 'completed':
        return const _TodoStatusStyle(
            Icons.check_circle_rounded, JcTheme.success, true);
      case 'in_progress':
        return const _TodoStatusStyle(
            Icons.autorenew_rounded, JcTheme.primaryBlue, false);
      case 'cancelled':
        return const _TodoStatusStyle(
            Icons.cancel_rounded, JcTheme.muted, true);
      case 'pending':
      default:
        return const _TodoStatusStyle(
            Icons.radio_button_unchecked_rounded, JcTheme.muted, false);
    }
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo});
  final Map<String, dynamic> todo;

  @override
  Widget build(BuildContext context) {
    final status = (todo['status'] ?? 'pending').toString();
    final content = (todo['content'] ?? '').toString();
    final style = _TodoStatusStyle.of(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(style.icon, size: 18, color: style.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  content,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: style.strikethrough ? JcTheme.muted : JcTheme.text,
                    decoration: style.strikethrough
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: JcTheme.muted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _statusLabel(status),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: style.color.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'in_progress':
        return 'IN PROGRESS';
      case 'completed':
        return 'COMPLETED';
      case 'cancelled':
        return 'CANCELLED';
      case 'pending':
      default:
        return 'PENDING';
    }
  }
}

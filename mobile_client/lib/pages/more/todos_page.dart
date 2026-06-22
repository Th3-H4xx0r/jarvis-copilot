import 'package:flutter/material.dart';

import '../../api/todos.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Read-only mirror of the webui "Todos" panel: the active chat session's
/// current todo list, derived from its message history (there is no todos API).
/// Each row shows a status icon + colour, the todo text (struck through when
/// completed/cancelled), and a small status pill. Active work (in-progress /
/// pending) is sorted to the top. Pull-to-refresh re-fetches.
class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  final AsyncViewController _ctrl = AsyncViewController();
  final TodosApi _api = TodosApi(app.api);

  /// Sort weight so active work surfaces first: in-progress, then pending,
  /// then completed, then cancelled. Stable within each group.
  static int _rank(String status) {
    switch (status) {
      case 'in_progress':
        return 0;
      case 'pending':
        return 1;
      case 'completed':
        return 2;
      case 'cancelled':
        return 3;
      default:
        return 1;
    }
  }

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
            // Render our own icon+text empty state inside the builder so it
            // stays a scrollable (pull-to-refresh keeps working).
            isEmpty: (_) => false,
            builder: (context, todos, refresh) {
              if (todos.isEmpty) {
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: const [
                    SizedBox(height: 100),
                    _TodosEmpty(),
                  ],
                );
              }

              final sorted = [...todos]..sort((a, b) {
                  final sa = (a['status'] ?? 'pending').toString();
                  final sb = (b['status'] ?? 'pending').toString();
                  return _rank(sa).compareTo(_rank(sb));
                });

              final done = sorted
                  .where((t) {
                    final s = (t['status'] ?? '').toString();
                    return s == 'completed' || s == 'cancelled';
                  })
                  .length;

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: sorted.length + 1,
                separatorBuilder: (_, i) =>
                    SizedBox(height: i == 0 ? 0 : 10),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SectionHeader(
                        'Active session',
                        trailing: Text(
                          '$done / ${sorted.length} done',
                          style: const TextStyle(
                              color: JcTheme.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    );
                  }
                  return _TodoCard(todo: sorted[i - 1]);
                },
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
  const _TodoStatusStyle(this.icon, this.color, this.label,
      {this.strikethrough = false, this.spin = false});
  final IconData icon;
  final Color color;
  final String label;
  final bool strikethrough;
  final bool spin;

  static _TodoStatusStyle of(String status) {
    switch (status) {
      case 'completed':
        return const _TodoStatusStyle(
            Icons.check_circle_rounded, JcTheme.success, 'COMPLETED',
            strikethrough: true);
      case 'in_progress':
        return const _TodoStatusStyle(
            Icons.autorenew_rounded, JcTheme.primaryBlue, 'IN PROGRESS',
            spin: true);
      case 'cancelled':
        return const _TodoStatusStyle(
            Icons.cancel_rounded, JcTheme.muted, 'CANCELLED',
            strikethrough: true);
      case 'pending':
      default:
        return const _TodoStatusStyle(
            Icons.radio_button_unchecked_rounded, JcTheme.muted, 'PENDING');
    }
  }
}

class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.todo});
  final Map<String, dynamic> todo;

  @override
  Widget build(BuildContext context) {
    final status = (todo['status'] ?? 'pending').toString();
    final content = (todo['content'] ?? '').toString();
    final style = _TodoStatusStyle.of(status);
    final active = status == 'in_progress';
    return GlassCard(
      blur: false,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: active
          ? JcTheme.primaryBlue.withValues(alpha: 0.40)
          : JcTheme.glassBorder,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: style.spin
                ? _SpinningIcon(icon: style.icon, color: style.color)
                : Icon(style.icon, size: 20, color: style.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  content.isEmpty ? '(empty)' : content,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: style.strikethrough ? JcTheme.muted : JcTheme.text,
                    decoration: style.strikethrough
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: JcTheme.muted,
                  ),
                ),
                const SizedBox(height: 8),
                StatusPill(
                  style.label,
                  color: style.color,
                  live: active,
                  dense: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The in-progress status icon, gently rotating to read as live work.
class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: Icon(widget.icon, size: 20, color: widget.color),
    );
  }
}

/// Polished icon + text empty state for when no active todo list exists.
class _TodosEmpty extends StatelessWidget {
  const _TodosEmpty();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: JcTheme.glassFill,
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Icon(Icons.checklist_rounded,
              size: 30, color: JcTheme.muted.withValues(alpha: 0.8)),
        ),
        const SizedBox(height: 16),
        const Text(
          'No active todo list.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: JcTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'When the active chat session has a plan, its todos show here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: JcTheme.muted, fontSize: 13, height: 1.4),
        ),
      ],
    );
  }
}

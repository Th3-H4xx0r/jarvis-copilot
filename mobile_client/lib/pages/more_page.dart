import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/glass.dart';
import 'logs_page.dart';
import 'more/code_memory_page.dart';
import 'more/insights_page.dart';
import 'more/kanban_page.dart';
import 'more/long_term_memory_page.dart';
import 'more/memory_page.dart';
import 'more/profiles_page.dart';
import 'more/server_logs_page.dart';
import 'more/tasks_page.dart';
import 'more/todos_page.dart';
import 'more/workspaces_page.dart';
import 'self_improvement_page.dart';
import 'settings_page.dart';

/// Grid of launchers. The 5 native tabs cover the hot paths; the rest
/// of the webui's tabs are reachable here via the embedded webview.
/// Each tile sets a deep-link path inside the server so the webview
/// loads straight into the target panel.
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  static const List<_MoreItem> _tiles = [
    _MoreItem('Tasks (cron)', Icons.schedule, _NativeRoute(TasksPage())),
    _MoreItem('Kanban', Icons.view_kanban, _NativeRoute(KanbanPage())),
    _MoreItem('Memory', Icons.memory, _NativeRoute(MemoryPage())),
    _MoreItem('Code memory', Icons.account_tree_outlined, _NativeRoute(CodeMemoryPage())),
    _MoreItem('Long-term memory', Icons.hub_outlined, _NativeRoute(LongTermMemoryPage())),
    _MoreItem('Workspaces', Icons.folder_outlined, _NativeRoute(WorkspacesPage())),
    _MoreItem('Profiles', Icons.person_outline, _NativeRoute(ProfilesPage())),
    _MoreItem('Todos', Icons.checklist, _NativeRoute(TodosPage())),
    _MoreItem('Insights', Icons.insights, _NativeRoute(InsightsPage())),
    _MoreItem('Learning', Icons.auto_awesome, _NativeRoute(SelfImprovementPage())),
    _MoreItem('Server logs', Icons.article_outlined, _NativeRoute(ServerLogsPage())),
    _MoreItem('This device logs', Icons.history, _NativeRoute(LogsPage())),
    _MoreItem('Settings', Icons.settings, _NativeRoute(SettingsPage())),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'More', back: false),
      body: AppBackground(
        child: SafeArea(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: _tiles.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemBuilder: (_, i) {
              final t = _tiles[i];
              return GlassCard(
                radius: 22,
                padding: const EdgeInsets.all(10),
                onTap: () {
                  final r = t.target;
                  if (r is _NativeRoute) {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => r.page,
                    ));
                  }
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: JcTheme.glassFill,
                        border: Border.all(color: JcTheme.glassBorder),
                      ),
                      child: Icon(t.icon, color: JcTheme.primaryBlue, size: 24),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      t.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: JcTheme.text,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MoreItem {
  const _MoreItem(this.label, this.icon, this.target);
  final String label;
  final IconData icon;
  final Object target;
}

class _NativeRoute {
  const _NativeRoute(this.page);
  final Widget page;
}

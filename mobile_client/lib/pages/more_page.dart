import 'package:flutter/material.dart';

import '../theme.dart';
import 'logs_page.dart';
import 'self_improvement_page.dart';
import 'settings_page.dart';
import 'webview_page.dart';

/// Grid of launchers. The 5 native tabs cover the hot paths; the rest
/// of the webui's tabs are reachable here via the embedded webview.
/// Each tile sets a deep-link path inside the server so the webview
/// loads straight into the target panel.
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  static const List<_MoreItem> _tiles = [
    _MoreItem('Tasks (cron)', Icons.schedule, _WebRoute('Tasks', '/?panel=tasks')),
    _MoreItem('Kanban', Icons.view_kanban, _WebRoute('Kanban', '/?panel=kanban')),
    _MoreItem('Memory', Icons.memory, _WebRoute('Memory', '/?panel=memory')),
    _MoreItem('Workspaces', Icons.folder_outlined, _WebRoute('Workspaces', '/?panel=workspaces')),
    _MoreItem('Profiles', Icons.person_outline, _WebRoute('Profiles', '/?panel=profiles')),
    _MoreItem('Todos', Icons.checklist, _WebRoute('Todos', '/?panel=todos')),
    _MoreItem('Insights', Icons.insights, _WebRoute('Insights', '/?panel=insights')),
    _MoreItem('Learning', Icons.auto_awesome, _NativeRoute(SelfImprovementPage())),
    _MoreItem('Server logs', Icons.article_outlined, _WebRoute('Server logs', '/?panel=logs')),
    _MoreItem('This device logs', Icons.history, _NativeRoute(LogsPage())),
    _MoreItem('Settings', Icons.settings, _NativeRoute(SettingsPage())),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(title: const Text('More')),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.95,
        ),
        itemBuilder: (_, i) {
          final t = _tiles[i];
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              final r = t.target;
              if (r is _WebRoute) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WebViewPage(title: r.title, path: r.path),
                ));
              } else if (r is _NativeRoute) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => r.page,
                ));
              }
            },
            child: Container(
              decoration: BoxDecoration(
                color: JcTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: JcTheme.border),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(t.icon, color: JcTheme.accent, size: 28),
                  const SizedBox(height: 10),
                  Text(
                    t.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        },
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

class _WebRoute {
  const _WebRoute(this.title, this.path);
  final String title;
  final String path;
}

class _NativeRoute {
  const _NativeRoute(this.page);
  final Widget page;
}

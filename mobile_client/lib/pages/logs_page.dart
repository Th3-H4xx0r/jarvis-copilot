import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../theme.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  @override
  Widget build(BuildContext context) {
    final log = app.runner.log;
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(
        title: const Text('Invocation log'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() {})),
        ],
      ),
      body: log.isEmpty
          ? const Center(
              child: Text(
                'No invocations yet.',
                style: TextStyle(color: JcTheme.muted),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: log.length,
              separatorBuilder: (_, __) => const Divider(height: 0),
              itemBuilder: (_, i) {
                final e = log[i];
                final isErr = e.error != null;
                return ListTile(
                  leading: Icon(
                    isErr ? Icons.error_outline : Icons.check_circle_outline,
                    color: isErr ? JcTheme.danger : JcTheme.success,
                  ),
                  title: Text(e.skill,
                      style: const TextStyle(fontFamily: 'monospace')),
                  subtitle: Text(
                    isErr ? e.error! : (e.result?.toString() ?? ''),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isErr ? JcTheme.danger : JcTheme.muted,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Text(
                    '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 11, color: JcTheme.muted),
                  ),
                );
              },
            ),
    );
  }
}

import 'package:flutter/material.dart';

import '../api/devices.dart';
import '../main.dart' as app;
import '../theme.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  late final DevicesApi _api = DevicesApi(app.api);
  List<Map<String, dynamic>> _devices = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _devices = await _api.list();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmAndDo(String title, String body, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(_error!, style: const TextStyle(color: JcTheme.danger)),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _devices.length,
                    itemBuilder: (_, i) {
                      final d = _devices[i];
                      final online = d['online'] == true;
                      final skills =
                          (d['skills'] as List?)?.cast<Map>() ?? const [];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: online
                                          ? JcTheme.success
                                          : JcTheme.muted,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      (d['name'] ?? 'device').toString(),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _confirmAndDo(
                                      'Log out device',
                                      'The device will need to re-authenticate.',
                                      () => _api.logout(d['id'].toString()),
                                    ),
                                    child: const Text('Log out'),
                                  ),
                                  TextButton(
                                    onPressed: () => _confirmAndDo(
                                      'Revoke device',
                                      'The device will be removed and logged out.',
                                      () => _api.revoke(d['id'].toString()),
                                    ),
                                    child: const Text('Revoke',
                                        style: TextStyle(color: JcTheme.danger)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${d['ip'] ?? '—'} · ${d['kind'] ?? 'browser'}',
                                style:
                                    const TextStyle(color: JcTheme.muted, fontSize: 12),
                              ),
                              if (skills.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: skills
                                      .map((s) => Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: JcTheme.surfaceAlt,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              (s['name'] ?? '').toString(),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: JcTheme.blue,
                                                  fontFamily: 'monospace'),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

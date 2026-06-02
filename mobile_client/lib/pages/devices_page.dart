import 'package:flutter/material.dart';

import '../api/devices.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

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
        backgroundColor: JcTheme.surface,
        title: Text(title, style: const TextStyle(color: JcTheme.text)),
        content: Text(body, style: const TextStyle(color: JcTheme.muted)),
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
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Devices',
        back: false,
        trailing: GlassIconButton(
          icon: Icons.refresh_rounded,
          onTap: _loading ? null : _refresh,
          color: _loading ? JcTheme.muted : JcTheme.text,
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: GlassCard(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: JcTheme.danger, size: 32),
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: const TextStyle(color: JcTheme.danger, fontSize: 14),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              GlassButton(
                                label: 'Retry',
                                icon: Icons.refresh_rounded,
                                onPressed: _refresh,
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: _devices.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 80),
                                Center(
                                  child: Text(
                                    'No devices found',
                                    style: TextStyle(color: JcTheme.muted, fontSize: 15),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: _devices.length,
                              itemBuilder: (_, i) {
                                final d = _devices[i];
                                final online = d['online'] == true;
                                final skills =
                                    (d['skills'] as List?)?.cast<Map>() ?? const [];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: _DeviceCard(
                                    device: d,
                                    online: online,
                                    skills: skills,
                                    onLogout: () => _confirmAndDo(
                                      'Log out device',
                                      'The device will need to re-authenticate.',
                                      () => _api.logout(d['id'].toString()),
                                    ),
                                    onRevoke: () => _confirmAndDo(
                                      'Revoke device',
                                      'The device will be removed and logged out.',
                                      () => _api.revoke(d['id'].toString()),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.online,
    required this.skills,
    required this.onLogout,
    required this.onRevoke,
  });

  final Map<String, dynamic> device;
  final bool online;
  final List<Map> skills;
  final VoidCallback onLogout;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final name = (device['name'] ?? 'device').toString();
    final meta = '${device['ip'] ?? '—'} · ${device['kind'] ?? 'browser'}';

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: status dot + name + action buttons
          Row(
            children: [
              // Circular status chip
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (online ? JcTheme.success : JcTheme.muted)
                      .withValues(alpha: 0.12),
                  border: Border.all(
                    color: (online ? JcTheme.success : JcTheme.muted)
                        .withValues(alpha: 0.30),
                  ),
                ),
                child: Icon(
                  online ? Icons.devices_rounded : Icons.devices_other_rounded,
                  size: 20,
                  color: online ? JcTheme.success : JcTheme.muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online ? JcTheme.success : JcTheme.muted,
                            boxShadow: online
                                ? [
                                    BoxShadow(
                                      color: JcTheme.success.withValues(alpha: 0.5),
                                      blurRadius: 6,
                                    )
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          online ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: online ? JcTheme.success : JcTheme.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Log out button (blue ghost pill)
              _ActionChip(label: 'Log out', onTap: onLogout, danger: false),
              const SizedBox(width: 8),
              // Revoke button (danger)
              _ActionChip(label: 'Revoke', onTap: onRevoke, danger: true),
            ],
          ),

          // Meta line: IP / kind
          const SizedBox(height: 10),
          Text(
            meta,
            style: const TextStyle(color: JcTheme.muted, fontSize: 12),
          ),

          // Skills chips
          if (skills.isNotEmpty) ...[
            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: JcTheme.glassBorder.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: skills
                  .map((s) => _SkillChip(name: (s['name'] ?? '').toString()))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small pill button used for Log out / Revoke actions inside a device card.
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.onTap,
    required this.danger,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? JcTheme.danger : JcTheme.primaryBlue;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Frosted skill name chip.
class _SkillChip extends StatelessWidget {
  const _SkillChip({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: JcTheme.primaryBlue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: JcTheme.primaryBlue.withValues(alpha: 0.25)),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 11,
          color: JcTheme.primaryBlueHi,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

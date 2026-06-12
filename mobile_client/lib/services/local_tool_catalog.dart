import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../skills/registry.dart';
import 'api_client.dart';
import 'on_device_ai_types.dart';

/// The catalog surface the [LocalRouter] depends on. Implemented by
/// [LocalToolCatalog] and faked in tests.
abstract interface class ToolCatalog {
  /// Compact JSON the local model sees: `[{"name","desc","execClass"}, ...]`.
  Future<String> buildPromptCatalog();

  /// Where a tool by [name] actually runs.
  ToolExecClass classOf(String name);
}

/// Assembles the tool list the on-device model is shown: device-local skills
/// (from the client [SkillRegistry]) merged with the full server tool list
/// (cached from `GET /api/tools/catalog`). Each tool is tagged with a
/// [ToolExecClass] so the router knows whether the client can run it locally or
/// must escalate to the server agent.
class LocalToolCatalog implements ToolCatalog {
  LocalToolCatalog({ApiClient? api, int maxTools = 64})
      : _api = api,
        _maxTools = maxTools;

  final ApiClient? _api;
  final int _maxTools;

  /// Cached server tools: `[{name, description, toolset, schema}]`.
  List<Map<String, dynamic>> _serverTools = const [];
  DateTime? _fetchedAt;

  /// Device skills that run fully on-device/offline (instant). Names MUST match
  /// the real [SkillRegistry] entries (lib/skills/*.dart). Anything else in the
  /// registry is treated as client-dispatchable (InvokeRunner can run it but it
  /// may hop the bridge / need the network).
  static const Set<String> _offlineSkillNames = {
    'set_alarm',
    'vibrate',
    'play_audio',
    'flashlight_on',
    'flashlight_off',
    'set_volume',
    'adjust_volume',
    'notify',
    'battery_level',
    'device_info',
    'clipboard_read',
    'clipboard_write',
    'get_location',
    'phone_control',
    'create_shortcut',
    'run_shortcut',
    'text_to_speech',
  };

  /// Refresh the cached server tool list. Safe to call opportunistically; a
  /// failure leaves the previous cache (or an empty one) in place.
  Future<void> refresh({Duration ttl = const Duration(hours: 6)}) async {
    final api = _api;
    if (api == null) return;
    final fetchedAt = _fetchedAt;
    if (fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < ttl &&
        _serverTools.isNotEmpty) {
      return;
    }
    try {
      final resp = await api.get('/api/tools/catalog');
      final data = resp.data;
      final raw = (data is Map) ? data['tools'] : null;
      if (raw is List) {
        _serverTools = raw
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
            .toList(growable: false);
        _fetchedAt = DateTime.now();
      }
    } catch (e) {
      debugPrint('[catalog] /api/tools/catalog fetch failed: $e');
    }
  }

  /// Test seam: inject a server tool list without hitting the network.
  @visibleForTesting
  void setServerToolsForTest(List<Map<String, dynamic>> tools) {
    _serverTools = List<Map<String, dynamic>>.from(tools);
    _fetchedAt = DateTime.now();
  }

  bool _isServerTool(String name) =>
      _serverTools.any((t) => (t['name'] ?? '').toString() == name);

  @override
  ToolExecClass classOf(String name) {
    final isSkill = SkillRegistry.instance.find(name) != null;
    if (isSkill) {
      return _offlineSkillNames.contains(name)
          ? ToolExecClass.deviceLocal
          : ToolExecClass.clientDispatchable;
    }
    if (_isServerTool(name)) return ToolExecClass.serverOnly;
    // Unknown name → safest is to escalate.
    return ToolExecClass.serverOnly;
  }

  @override
  Future<String> buildPromptCatalog() async {
    // Only show the model what it can ACTUALLY execute on-device (the device
    // skills). Server-only tools are deliberately NOT listed — otherwise the
    // small model thinks it can fetch weather/calendar/email itself and
    // fabricates results instead of escalating. Anything not listed → escalate.
    final entries = <Map<String, String>>[];
    final seen = <String>{};
    for (final s in SkillRegistry.instance.all()) {
      if (!seen.add(s.name)) continue;
      entries.add({
        'name': s.name,
        'desc': _short(s.description),
      });
    }
    if (entries.length > _maxTools) {
      entries.removeRange(_maxTools, entries.length);
    }
    return jsonEncode(entries);
  }

  static String _short(String s, [int max = 80]) {
    final one = s.replaceAll('\n', ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max - 1)}…';
  }
}

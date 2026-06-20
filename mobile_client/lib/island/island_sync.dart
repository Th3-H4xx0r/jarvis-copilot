import 'package:flutter/services.dart';

import 'island_models.dart';

/// Thin wrapper over the native `jarviscopilot/island` channel that caches
/// design definitions into the iOS App Group container, where the widget
/// extension reads them. Fire-and-forget; swallows channel errors (Android has
/// no handler — designs are an iOS-only feature).
class IslandNative {
  static const _ch = MethodChannel('jarviscopilot/island');

  static Future<void> cacheDesigns(List<IslandDesign> designs) async {
    if (designs.isEmpty) return;
    final payload = designs
        .map((d) => {'id': d.id, 'version': d.version, 'json': d.jsonString})
        .toList(growable: false);
    try {
      await _ch.invokeMethod('cacheDesigns', {'designs': payload});
    } catch (_) {}
  }

  static Future<void> clearCache() async {
    try {
      await _ch.invokeMethod('clearDesignCache');
    } catch (_) {}
  }
}

/// Caches design definitions to the App Group, re-pushing only the ones whose
/// CONTENT changed since last sync — keyed on [IslandDesign.contentSig] (the
/// whole tree), NOT `version`, so a layout edit re-caches live even when Jarvis
/// doesn't bump the version. A steady catalog produces no channel chatter.
class IslandSync {
  final Map<String, int> _cached = {}; // id -> content signature

  Future<void> sync(List<IslandDesign> designs) async {
    final ids = designs.map((d) => d.id).toSet();
    // A design disappeared from the catalog → clear the whole App Group cache and
    // re-push, so stale design-<id>.json files don't linger on device.
    final removed = _cached.keys.where((id) => !ids.contains(id)).isNotEmpty;
    if (removed) {
      await IslandNative.clearCache();
      _cached.clear();
    }
    final changed = <IslandDesign>[];
    for (final d in designs) {
      if (_cached[d.id] != d.contentSig) changed.add(d);
    }
    if (changed.isEmpty) return;
    await IslandNative.cacheDesigns(changed);
    for (final d in changed) {
      _cached[d.id] = d.contentSig;
    }
  }

  void reset() => _cached.clear();
}

import 'dart:convert';

/// Models for the Dynamic Island Designs feature (iOS only).
///
/// The Flutter side does NOT render the layout tree (the iOS widget does that
/// from a cached copy) — so a [IslandDesign] keeps the tree as an opaque `raw`
/// map it can cache + introspect for bindings, while the catalog/selection drive
/// the settings tab and the auto-selection engine.

/// A full custom design: identity + the opaque layout tree (`raw`).
class IslandDesign {
  const IslandDesign({
    required this.id,
    required this.name,
    required this.icon,
    required this.version,
    required this.raw,
  });

  final String id;
  final String name;
  final String icon;
  final int version;
  final Map<String, dynamic> raw;

  /// The full tree as JSON — what gets cached into the iOS App Group container.
  String get jsonString => jsonEncode(raw);

  /// A signature of the design's CONTENT (the whole tree), not just its version.
  /// Drives cache-busting + push de-dupe so a layout edit applies live even when
  /// Jarvis forgets to bump `version`.
  int get contentSig => jsonString.hashCode;

  factory IslandDesign.fromJson(Map<String, dynamic> m) => IslandDesign(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? m['id'] ?? '').toString(),
        icon: (m['icon'] ?? '').toString(),
        version: _asInt(m['version'], 1),
        raw: Map<String, dynamic>.from(m),
      );
}

/// Catalog metadata + auto-rules for one entry (a custom design OR a built-in
/// `voice`/`coding` mode). Drives the settings list and the auto picker.
class IslandCatalogEntry {
  const IslandCatalogEntry({
    required this.id,
    required this.name,
    required this.icon,
    required this.version,
    required this.builtin,
    required this.enabled,
    required this.priority,
    this.conditions,
    this.schedule,
  });

  final String id;
  final String name;
  final String icon;
  final int version;
  final bool builtin;
  final bool enabled;
  final int priority;

  /// Condition expression (see island_bindings.evaluateCondition); null = always.
  final Map<String, dynamic>? conditions;

  /// {days:[1-7]? (Mon=1…Sun=7), from:"HH:MM", to:"HH:MM"} or null = any time.
  final Map<String, dynamic>? schedule;

  bool get isVoice => id == 'voice';
  bool get isCoding => id == 'coding';

  factory IslandCatalogEntry.fromJson(Map<String, dynamic> m) =>
      IslandCatalogEntry(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? m['id'] ?? '').toString(),
        icon: (m['icon'] ?? '').toString(),
        version: _asInt(m['version'], 1),
        builtin: m['builtin'] == true,
        enabled: m['enabled'] != false, // default enabled
        priority: _asInt(m['priority'], 0),
        conditions: _asMap(m['conditions']),
        schedule: _asMap(m['schedule']),
      );
}

/// Which design is shown: `auto` (rules pick) or `pinned` (a specific entry).
class IslandSelection {
  const IslandSelection({required this.mode, this.pinnedId});

  final String mode; // 'auto' | 'pinned'
  final String? pinnedId;

  bool get isAuto => mode == 'auto';
  bool get isPinned => mode == 'pinned';

  factory IslandSelection.fromJson(Map<String, dynamic>? m) {
    final mode = (m?['mode'] ?? 'auto').toString();
    return IslandSelection(
      mode: mode == 'pinned' ? 'pinned' : 'auto',
      pinnedId: m?['pinnedId']?.toString(),
    );
  }

  static const auto = IslandSelection(mode: 'auto');
}

/// The whole GET /api/island/designs payload.
class IslandCatalog {
  const IslandCatalog({
    required this.designs,
    required this.entries,
    required this.selection,
    required this.data,
  });

  final List<IslandDesign> designs;
  final List<IslandCatalogEntry> entries;
  final IslandSelection selection;

  /// Per-design server-resolved values (jarvis.* etc.), keyed by design id.
  final Map<String, Map<String, dynamic>> data;

  IslandDesign? designById(String id) {
    for (final d in designs) {
      if (d.id == id) return d;
    }
    return null;
  }

  IslandCatalogEntry? entryById(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Map<String, dynamic> dataFor(String id) => data[id] ?? const {};

  static const empty = IslandCatalog(
    designs: [], entries: [], selection: IslandSelection.auto, data: {});

  factory IslandCatalog.fromJson(Map<String, dynamic> m) {
    final designs = ((m['designs'] as List?) ?? const [])
        .whereType<Map>()
        .map((d) => IslandDesign.fromJson(Map<String, dynamic>.from(d)))
        .toList(growable: false);
    final entries = ((m['catalog'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => IslandCatalogEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
    final rawData = (m['data'] as Map?) ?? const {};
    final data = <String, Map<String, dynamic>>{};
    rawData.forEach((k, v) {
      if (v is Map) data[k.toString()] = Map<String, dynamic>.from(v);
    });
    return IslandCatalog(
      designs: designs,
      entries: entries,
      selection: IslandSelection.fromJson(_asMap(m['selection'])),
      data: data,
    );
  }
}

int _asInt(dynamic v, int dflt) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? dflt;
  return dflt;
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

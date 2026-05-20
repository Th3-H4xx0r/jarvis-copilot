import 'dart:async';

/// One registered mobile skill. Mirrors the manifest entry shape that
/// the device bridge expects:
///   { name, description, input_schema }
typedef SkillRunner = FutureOr<Object?> Function(Map<String, dynamic> args);

class SkillEntry {
  SkillEntry({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.platform = 'any', // "any", "ios", "android"
    this.requiresOptIn = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final SkillRunner run;
  final String platform;
  final bool requiresOptIn;

  Map<String, dynamic> toManifest() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
}

/// Process-wide skill registry. Populated at app boot by
/// [registerCommonSkills] + the platform-specific files.
class SkillRegistry {
  SkillRegistry._();
  static final SkillRegistry instance = SkillRegistry._();

  final Map<String, SkillEntry> _byName = {};

  void register(SkillEntry entry) {
    _byName[entry.name] = entry;
  }

  SkillEntry? find(String name) => _byName[name];

  List<SkillEntry> all() => _byName.values.toList(growable: false);

  List<String> names() => _byName.keys.toList(growable: false)..sort();

  /// Manifest the bridge sends in the register frame.
  List<Map<String, dynamic>> manifest({Set<String> disabled = const {}}) {
    return _byName.values
        .where((e) => !disabled.contains(e.name))
        .map((e) => e.toManifest())
        .toList(growable: false);
  }
}

/// Convenience helper used by the platform-specific files.
void registerCommonSkills(List<SkillEntry> entries) {
  for (final e in entries) {
    SkillRegistry.instance.register(e);
  }
}

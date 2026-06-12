import 'package:flutter/material.dart';

import '../api/models.dart';
import '../main.dart' as app;
import '../services/model_selection.dart';
import '../services/on_device_ai_types.dart';
import '../theme.dart';
import 'glass.dart';

/// A model option parsed out of /api/models.
class _ModelOption {
  _ModelOption({
    required this.id,
    required this.label,
    required this.provider,
    required this.providerId,
  });

  /// The model id sent to the server (e.g. "anthropic/claude-opus-4.7").
  final String id;

  /// Human-facing model name (e.g. "Claude Opus 4.7").
  final String label;

  /// Human-facing provider name (e.g. "Anthropic").
  final String provider;

  /// Canonical provider id used for routing (e.g. "anthropic", "custom:foo").
  /// May be empty when the server didn't supply one — we then fall back to the
  /// display [provider].
  final String providerId;

  /// What we persist as the provider for a selection.
  String get providerForSave => providerId.isNotEmpty ? providerId : provider;
}

class _ModelGroup {
  _ModelGroup({required this.provider, required this.models});
  final String provider;
  final List<_ModelOption> models;
}

class _CatalogResult {
  _CatalogResult({
    required this.groups,
    required this.activeProvider,
    required this.defaultModel,
  });
  final List<_ModelGroup> groups;
  final String? activeProvider;
  final String? defaultModel;
}

/// Parse the /api/models payload into provider groups. Defensive: tolerates
/// missing keys, non-list groups, and model entries missing id/label.
///
/// Expected shape (see webui/api/config.py get_available_models):
///   {
///     "active_provider": str|null,
///     "default_model": str,
///     "groups": [
///       {"provider": str, "provider_id": str, "models": [{"id": str, "label": str}]}
///     ]
///   }
_CatalogResult _parseCatalog(Map<String, dynamic> data) {
  final groups = <_ModelGroup>[];
  final rawGroups = data['groups'];
  if (rawGroups is List) {
    for (final g in rawGroups) {
      if (g is! Map) continue;
      final providerName = (g['provider'] ?? '').toString().trim();
      final providerId = (g['provider_id'] ?? '').toString().trim();
      final rawModels = g['models'];
      if (rawModels is! List) continue;
      final models = <_ModelOption>[];
      for (final m in rawModels) {
        if (m is! Map) continue;
        final id = (m['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        final label = (m['label'] ?? m['id'] ?? '').toString().trim();
        models.add(_ModelOption(
          id: id,
          label: label.isEmpty ? id : label,
          provider: providerName.isEmpty ? (providerId.isEmpty ? 'Models' : providerId) : providerName,
          providerId: providerId,
        ));
      }
      if (models.isNotEmpty) {
        groups.add(_ModelGroup(
          provider: providerName.isEmpty ? (providerId.isEmpty ? 'Models' : providerId) : providerName,
          models: models,
        ));
      }
    }
  }
  return _CatalogResult(
    groups: groups,
    activeProvider: (data['active_provider'])?.toString(),
    defaultModel: (data['default_model'])?.toString(),
  );
}

/// Open the model picker for [surface]. Loads /api/models, shows the available
/// models grouped by provider in a glass bottom sheet, marks the currently
/// selected model (or the server's active/default when none is set), and on tap
/// persists the choice via [ModelSelection.instance.setFor] and closes.
Future<void> showModelPickerSheet(
  BuildContext context,
  VoiceSurface surface,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ModelPickerSheet(surface: surface),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.surface});
  final VoiceSurface surface;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  _CatalogResult? _catalog;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ModelsApi(app.api).list();
      final parsed = _parseCatalog(data);
      if (!mounted) return;
      setState(() {
        _catalog = parsed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _pick(_ModelOption option) async {
    await ModelSelection.instance.setFor(
      widget.surface,
      model: option.id,
      provider: option.providerForSave,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String get _title =>
      widget.surface == VoiceSurface.voice ? 'Voice model' : 'Chat model';

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // The currently-selected model id for this surface, if any.
    final selectedId = ModelSelection.instance.modelFor(widget.surface);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: JcTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Text(
              _title,
              style: const TextStyle(
                color: JcTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose the server model for this surface.',
              style: TextStyle(color: JcTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Flexible(child: _body(selectedId)),
          ],
        ),
      ),
    );
  }

  Widget _body(String? selectedId) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.cloud_off_rounded, color: JcTheme.muted, size: 32),
            const SizedBox(height: 12),
            const Text(
              "Couldn't load models",
              textAlign: TextAlign.center,
              style: TextStyle(color: JcTheme.text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '$_error',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: JcTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            GlassButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              ghost: true,
              onPressed: _load,
            ),
          ],
        ),
      );
    }

    final catalog = _catalog;
    if (catalog == null || catalog.groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            'No models available.',
            style: TextStyle(color: JcTheme.muted),
          ),
        ),
      );
    }

    // When nothing is explicitly selected, fall back to the server's default
    // model so the user still sees a checkmark on "where they are".
    final effectiveSelected = selectedId ?? catalog.defaultModel;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in catalog.groups) ...[
            glassSectionLabel(group.provider),
            GlassGroup(
              blur: false,
              children: [
                for (var i = 0; i < group.models.length; i++)
                  _modelRow(
                    group.models[i],
                    selected: group.models[i].id == effectiveSelected,
                    last: i == group.models.length - 1,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _modelRow(_ModelOption option,
      {required bool selected, required bool last}) {
    return Column(
      children: [
        ListTile(
          onTap: () => _pick(option),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          title: Text(
            option.label,
            style: TextStyle(
              color: JcTheme.text,
              fontSize: 15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          trailing: selected
              ? const Icon(Icons.check_rounded, color: JcTheme.primaryBlueHi)
              : null,
        ),
        if (!last)
          const Divider(height: 1, indent: 16, color: JcTheme.glassBorder),
      ],
    );
  }

  Widget _grabber() => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: JcTheme.muted.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// A tappable pill showing the current model selection for [surface]. Drop it
/// into a chat/voice header — tapping opens [showModelPickerSheet].
///
/// Shows the persisted model label when one is set, otherwise a neutral
/// "Auto" label (meaning: use the server's active/default model).
class ModelChip extends StatefulWidget {
  const ModelChip({super.key, required this.surface, this.compact = false});

  final VoiceSurface surface;

  /// When true, renders a tighter pill (icon + short label) for dense headers.
  final bool compact;

  @override
  State<ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<ModelChip> {
  Future<void> _open() async {
    await showModelPickerSheet(context, widget.surface);
    if (mounted) setState(() {}); // reflect a possibly-changed selection
  }

  /// Best-effort short label from a model id. We don't have the catalog handy
  /// here, so derive a readable name from the id's last segment.
  String _label() {
    final model = ModelSelection.instance.modelFor(widget.surface);
    if (model == null || model.isEmpty) return 'Auto';
    var s = model;
    final slash = s.lastIndexOf('/');
    if (slash >= 0 && slash < s.length - 1) s = s.substring(slash + 1);
    final colon = s.lastIndexOf(':');
    if (colon >= 0 && colon < s.length - 1) s = s.substring(colon + 1);
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final label = _label();
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _open,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 10 : 12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: JcTheme.glassFill,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  size: 14, color: JcTheme.muted),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.compact ? 110 : 180),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more_rounded,
                  size: 16, color: JcTheme.muted),
            ],
          ),
        ),
      ),
    );
  }
}

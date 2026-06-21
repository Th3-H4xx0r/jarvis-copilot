import 'package:flutter/material.dart';

import '../theme.dart';

/// An OPAQUE modal bottom sheet for create/edit forms. Opaque
/// ([JcTheme.surface]) is deliberate — translucent sheets bleed the aurora
/// backdrop through (the recurring JARVIS-skin gotcha).
///
/// [onSave] returns true on success (sheet pops with `true`) or false to keep
/// the sheet open (e.g. validation failed and a SnackBar was shown).
Future<bool?> showFormSheet({
  required BuildContext context,
  required String title,
  required List<Widget> fields,
  required Future<bool> Function() onSave,
  String saveLabel = 'Save',
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: JcTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => _FormSheetBody(
      title: title,
      fields: fields,
      onSave: onSave,
      saveLabel: saveLabel,
    ),
  );
}

class _FormSheetBody extends StatefulWidget {
  const _FormSheetBody({
    required this.title,
    required this.fields,
    required this.onSave,
    required this.saveLabel,
  });

  final String title;
  final List<Widget> fields;
  final Future<bool> Function() onSave;
  final String saveLabel;

  @override
  State<_FormSheetBody> createState() => _FormSheetBodyState();
}

class _FormSheetBodyState extends State<_FormSheetBody> {
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final ok = await widget.onSave();
      if (ok && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: JcTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.title,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ...widget.fields,
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(widget.saveLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Labelled multiline-capable text field for use inside [showFormSheet].
class FormTextField extends StatelessWidget {
  const FormTextField({
    super.key,
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.hint,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final int maxLines;
  final String? hint;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            keyboardType: keyboardType,
            style: const TextStyle(color: JcTheme.text),
            decoration: InputDecoration(hintText: hint, isDense: true),
          ),
        ],
      ),
    );
  }
}

/// Labelled dropdown for use inside [showFormSheet].
class FormDropdown<T> extends StatelessWidget {
  const FormDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          const SizedBox(height: 6),
          DropdownButtonFormField<T>(
            initialValue: value,
            isExpanded: true,
            dropdownColor: JcTheme.surfaceAlt,
            items: items,
            onChanged: onChanged,
            decoration: const InputDecoration(isDense: true),
          ),
        ],
      ),
    );
  }
}

/// Labelled on/off switch for use inside [showFormSheet].
class FormToggle extends StatelessWidget {
  const FormToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(color: JcTheme.text, fontSize: 15)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: JcTheme.accent,
      ),
    );
  }
}

/// Multi-select chip row for use inside [showFormSheet].
class FormChipMulti extends StatelessWidget {
  const FormChipMulti({
    super.key,
    required this.label,
    required this.all,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> all;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: all.map((item) {
              final on = selected.contains(item);
              return FilterChip(
                label: Text(item),
                selected: on,
                onSelected: (v) {
                  final next = Set<String>.from(selected);
                  if (v) {
                    next.add(item);
                  } else {
                    next.remove(item);
                  }
                  onChanged(next);
                },
                backgroundColor: JcTheme.surfaceAlt,
                selectedColor: JcTheme.accent.withValues(alpha: 0.3),
                checkmarkColor: JcTheme.accent,
                labelStyle: TextStyle(color: on ? JcTheme.text : JcTheme.muted),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

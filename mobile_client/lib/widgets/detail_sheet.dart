import 'package:flutter/material.dart';

import '../theme.dart';

/// An OPAQUE scrollable bottom sheet for showing a record's full detail plus
/// action buttons. Opaque ([JcTheme.surface]) on purpose — see [showFormSheet].
///
/// Caps at 85% of screen height and scrolls. Pop with a value via
/// `Navigator.of(context).pop(result)` from inside [child] (e.g. after a
/// mutation) so the caller can react.
Future<T?> showDetailSheet<T>({
  required BuildContext context,
  required String title,
  required Widget child,
  List<Widget>? actions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: JcTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
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
                title,
                style: const TextStyle(
                    color: JcTheme.text, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: child)),
              if (actions != null && actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// A simple label/value row for detail sheets.
class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: JcTheme.text, fontSize: 15)),
        ],
      ),
    );
  }
}

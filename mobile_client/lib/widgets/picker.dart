import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// One selectable option in a [PickerField] / [showPickerSheet].
class PickerOption<T> {
  const PickerOption(this.value, this.label, {this.subtitle, this.icon});
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
}

/// A thin gradient-hairline border — the app's "futuristic glass edge". Wraps
/// [child] in a 1.2px iridescent (or accent) gradient outline over a solid fill.
class GradientBorder extends StatelessWidget {
  const GradientBorder({
    super.key,
    required this.child,
    this.radius = 14,
    this.fill,
    this.gradient,
    this.thickness = 1.2,
    this.glow = false,
  });

  final Widget child;
  final double radius;
  final Color? fill;
  final Gradient? gradient;
  final double thickness;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final g = gradient ??
        const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x5546E0E0), Color(0x558A7CFF), Color(0x55FF6FD8)],
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + thickness),
        gradient: g,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: JcTheme.accent.withValues(alpha: 0.20),
                  blurRadius: 16,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      padding: EdgeInsets.all(thickness),
      child: Container(
        decoration: BoxDecoration(
          color: fill ?? JcTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

/// A modern select field: a gradient-edged glass pill showing the current
/// value, opening a themed bottom-sheet picker on tap. Replaces the stock
/// Material dropdown (whose menu can't be themed to match the app).
class PickerField<T> extends StatelessWidget {
  const PickerField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint = 'Select',
    this.sheetTitle,
  });

  final T value;
  final List<PickerOption<T>> options;
  final ValueChanged<T?> onChanged;
  final String hint;
  final String? sheetTitle;

  @override
  Widget build(BuildContext context) {
    PickerOption<T>? current;
    for (final o in options) {
      if (o.value == value) {
        current = o;
        break;
      }
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () async {
          FocusScope.of(context).unfocus();
          final picked = await showPickerSheet<T>(
            context: context,
            title: sheetTitle ?? hint,
            options: options,
            selected: value,
          );
          if (picked != null) onChanged(picked);
        },
        child: GradientBorder(
          radius: 14,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
            child: Row(
              children: [
                if (current?.icon != null) ...[
                  Icon(current!.icon, size: 18, color: JcTheme.cyan),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    current?.label ?? hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current == null ? JcTheme.muted : JcTheme.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.expand_more_rounded,
                    color: JcTheme.muted, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A themed modal picker. Dark frosted sheet with a gradient top accent; the
/// selected row gets an iridescent tint + left accent bar + a cyan check.
Future<T?> showPickerSheet<T>({
  required BuildContext context,
  required String title,
  required List<PickerOption<T>> options,
  T? selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: JcTheme.surface.withValues(alpha: 0.96),
              border: const Border(
                top: BorderSide(color: Color(0x33FFFFFF), width: 0.6),
              ),
            ),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Gradient accent strip + grab handle.
                Container(
                  height: 3,
                  width: double.infinity,
                  decoration: const BoxDecoration(gradient: JcTheme.brandGradient),
                ),
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 6),
                  decoration: BoxDecoration(
                    color: JcTheme.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: JcTheme.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                    itemCount: options.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) {
                      final o = options[i];
                      final isSel = o.value == selected;
                      return _PickerRow<T>(
                        option: o,
                        selected: isSel,
                        onTap: () => Navigator.of(ctx).pop(o.value),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });
  final PickerOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: selected
                ? LinearGradient(
                    colors: [
                      JcTheme.accent.withValues(alpha: 0.22),
                      JcTheme.cyan.withValues(alpha: 0.06),
                    ],
                  )
                : null,
            color: selected ? null : JcTheme.glassFill,
            border: Border.all(
              color: selected
                  ? JcTheme.accent.withValues(alpha: 0.45)
                  : JcTheme.glassBorder,
              width: selected ? 1 : 0.8,
            ),
          ),
          child: Row(
            children: [
              if (option.icon != null) ...[
                Icon(option.icon,
                    size: 19,
                    color: selected ? JcTheme.cyan : JcTheme.muted),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        color: JcTheme.text,
                        fontSize: 15.5,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (option.subtitle != null &&
                        option.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(option.subtitle!,
                          style: const TextStyle(
                              color: JcTheme.muted, fontSize: 12.5)),
                    ],
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: JcTheme.cyan, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

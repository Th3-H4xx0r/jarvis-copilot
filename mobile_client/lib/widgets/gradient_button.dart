import 'package:flutter/material.dart';

import '../theme.dart';

/// Primary CTA — gold→amber gradient, matches the webui "primary" button.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.full = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.black,
            ),
          )
        else if (icon != null)
          Icon(icon, size: 18, color: Colors.black),
        if (icon != null || busy) const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: Colors.black),
        ),
      ],
    );
    return Opacity(
      opacity: onPressed == null && !busy ? 0.45 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            gradient: JcTheme.brandGradient,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66E0552B),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

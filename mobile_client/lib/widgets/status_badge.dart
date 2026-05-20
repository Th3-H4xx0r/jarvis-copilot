import 'package:flutter/material.dart';

import '../theme.dart';

enum BridgeStatus { offline, connecting, online }

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.label});
  final BridgeStatus status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    Color color;
    String text;
    switch (status) {
      case BridgeStatus.offline:
        color = JcTheme.muted;
        text = label ?? 'offline';
        break;
      case BridgeStatus.connecting:
        color = JcTheme.accent;
        text = label ?? 'connecting…';
        break;
      case BridgeStatus.online:
        color = JcTheme.success;
        text = label ?? 'online';
        break;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: status == BridgeStatus.online
                ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 11.5)),
      ],
    );
  }
}

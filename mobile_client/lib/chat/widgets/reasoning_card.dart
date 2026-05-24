import 'package:flutter/material.dart';

import '../../theme.dart';

/// Collapsible "Thinking" trace — mirrors the webui's `.thinking-card`.
/// Collapsed by default; while the model is still reasoning we show a
/// subtle pulsing label so the user knows work is happening.
class ReasoningCard extends StatefulWidget {
  const ReasoningCard({
    super.key,
    required this.text,
    this.active = false,
  });

  final String text;
  final bool active;

  @override
  State<ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<ReasoningCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: JcTheme.accent.withValues(alpha: 0.07),
        border: Border.all(color: JcTheme.accent.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 13, color: JcTheme.accent),
                  const SizedBox(width: 7),
                  Text(
                    widget.active ? 'Thinking…' : 'Thought process',
                    style: const TextStyle(
                      color: JcTheme.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.chevron_right,
                        size: 16, color: JcTheme.accent.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.text.trim(),
                    style: TextStyle(
                      color: JcTheme.text.withValues(alpha: 0.85),
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';

/// A markdown widget that updates as text grows. We could re-create
/// MarkdownBody on every frame and let Flutter diff, but for long
/// streams that's expensive — instead we hold our own buffer and
/// rebuild only when the input actually changes. The trade-off is
/// that mid-stream the markdown may render partial syntax (an opening
/// "```" without a closing fence) and the renderer falls back to
/// inline rendering until the close arrives, which is the same
/// behaviour the webui shows.
class MarkdownStream extends StatelessWidget {
  const MarkdownStream({super.key, required this.text, this.style});

  final String text;
  final MarkdownStyleSheet? style;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: text.isEmpty ? '…' : text,
      selectable: true,
      softLineBreak: true,
      styleSheet: style ??
          MarkdownStyleSheet(
            p: const TextStyle(
              color: JcTheme.text,
              fontSize: 14,
              height: 1.45,
            ),
            code: const TextStyle(
              fontFamily: 'monospace',
              color: JcTheme.accent,
              backgroundColor: Color(0x33000000),
            ),
            codeblockDecoration: BoxDecoration(
              color: const Color(0xFF0F1830),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: JcTheme.border),
            ),
            h1: const TextStyle(
                color: JcTheme.text,
                fontSize: 22,
                fontWeight: FontWeight.w700),
            h2: const TextStyle(
                color: JcTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w700),
            blockquoteDecoration: BoxDecoration(
              border: const Border(
                left: BorderSide(color: JcTheme.accent, width: 3),
              ),
              color: JcTheme.surfaceAlt.withValues(alpha: 0.5),
            ),
          ),
    );
  }
}

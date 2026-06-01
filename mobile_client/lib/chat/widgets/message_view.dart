import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../../widgets/markdown_stream.dart';
import '../chat_models.dart';
import 'reasoning_card.dart';
import 'tool_card.dart';

/// Renders one [ChatMessage]. User turns are a right-aligned bubble;
/// assistant turns are a left-aligned column of markdown text blocks,
/// tool cards, and an optional thinking card — matching the webui's
/// message layout.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) return _UserBubble(message: message);
    return _AssistantTurn(message: message);
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 6, 4, 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: JcTheme.accent.withValues(alpha: 0.16),
          border: Border.all(color: JcTheme.accent.withValues(alpha: 0.30)),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SelectableText(
              message.plainText,
              style: const TextStyle(
                color: JcTheme.text,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (message.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final a in message.attachments)
                      _AttachmentChip(name: a),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    // Header row: small avatar + role label.
    children.add(Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              gradient: JcTheme.brandGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'J',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 7),
          const Text(
            'JarvisCopilot',
            style: TextStyle(
              color: JcTheme.muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ));

    if (message.reasoning.trim().isNotEmpty) {
      children.add(ReasoningCard(
        text: message.reasoning,
        active: message.streaming && message.plainText.isEmpty,
      ));
    }

    for (final block in message.blocks) {
      if (block is TextBlock) {
        if (block.text.trim().isEmpty) continue;
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: message.isError
              ? _ErrorText(block.text)
              : MarkdownStream(text: block.text),
        ));
      } else if (block is ToolBlock) {
        children.add(ToolCard(tool: block.tool));
      }
    }

    // Streaming placeholder: a thinking dot before any content arrives.
    if (message.streaming &&
        message.blocks.every((b) => b is! TextBlock || (b).text.trim().isEmpty) &&
        message.reasoning.trim().isEmpty) {
      children.add(const _TypingDots());
    }

    // Copy action for finished assistant text.
    if (!message.streaming && message.plainText.trim().isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: _CopyButton(text: message.plainText),
      ));
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(4, 6, 24, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: JcTheme.danger.withValues(alpha: 0.08),
        border: const Border(left: BorderSide(color: JcTheme.danger, width: 2)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: JcTheme.danger, fontSize: 13, height: 1.4),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: JcTheme.bg.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: JcTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.attach_file, size: 12, color: JcTheme.muted),
          const SizedBox(width: 4),
          Text(name,
              style: const TextStyle(color: JcTheme.muted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Icon(Icons.copy_all_outlined, size: 14, color: JcTheme.muted),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
            children: List.generate(3, (i) {
              final phase = (_c.value + i * 0.2) % 1.0;
              final o = 0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
              return Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Opacity(
                  opacity: o.clamp(0.3, 1.0),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: JcTheme.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

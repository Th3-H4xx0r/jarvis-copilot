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
  const MessageView({super.key, required this.message, this.onRetryOnServer});

  final ChatMessage message;

  /// Tapped on an on-device reply to re-ask the same prompt on the server.
  final VoidCallback? onRetryOnServer;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) return _UserBubble(message: message);
    return _AssistantTurn(message: message, onRetryOnServer: onRetryOnServer);
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(left: 44),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: JcTheme.slate,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SelectableText(
                message.plainText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              if (message.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < message.attachments.length; i++)
                        _AttachmentChip(
                          name: message.attachments[i],
                          thumb: i < message.attachmentThumbs.length
                              ? message.attachmentThumbs[i]
                              : null,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Assistant turn: a small avatar beside one translucent card that holds the
/// tool rows, the text, or the thinking indicator; a quiet stats line beneath.
class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.message, this.onRetryOnServer});
  final ChatMessage message;
  final VoidCallback? onRetryOnServer;

  @override
  Widget build(BuildContext context) {
    final tools = message.blocks.whereType<ToolBlock>().toList();
    final hasText = message.blocks
        .any((b) => b is TextBlock && b.text.trim().isNotEmpty);
    final content = <Widget>[];

    if (message.reasoning.trim().isNotEmpty) {
      content.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ReasoningCard(
          text: message.reasoning,
          active: message.streaming && !hasText,
        ),
      ));
    }

    if (tools.isNotEmpty) {
      content.add(Padding(
        padding: EdgeInsets.only(bottom: hasText || message.streaming ? 8 : 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in tools)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ToolCard(tool: t.tool),
              ),
          ],
        ),
      ));
    }

    for (final block in message.blocks) {
      if (block is TextBlock && block.text.trim().isNotEmpty) {
        content.add(message.isError
            ? _ErrorText(block.text)
            : MarkdownStream(text: block.text));
      }
    }

    if (message.streaming && !hasText) {
      final running = tools.isNotEmpty && !tools.last.tool.done
          ? 'Running ${tools.last.tool.label}…'
          : (message.reasoning.trim().isNotEmpty ? 'Thinking…' : null);
      content.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const _TypingDots(),
          if (running != null) ...[
            const SizedBox(width: 8),
            Text(running,
                style: const TextStyle(color: JcTheme.muted, fontSize: 12.5)),
          ],
        ]),
      ));
    }

    final status = message.streaming ? null : _statusLine(message);

    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: JcTheme.accent.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: message.onDevice
                    ? const Icon(Icons.bolt_rounded, size: 13, color: JcTheme.cyan)
                    : const Icon(Icons.auto_awesome, size: 13, color: JcTheme.accent),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: content,
                  ),
                ),
              ),
            ],
          ),
          if (status != null || (!message.streaming && message.plainText.trim().isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 4),
              child: Row(children: [
                if (status != null)
                  Text(status,
                      style: const TextStyle(
                        color: JcTheme.muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()],
                      )),
                if (!message.streaming && message.plainText.trim().isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _CopyButton(text: message.plainText),
                ],
                if (!message.streaming && message.onDevice && onRetryOnServer != null) ...[
                  const SizedBox(width: 6),
                  _TryServerButton(onTap: onRetryOnServer!),
                ],
              ]),
            ),
        ],
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
  const _AttachmentChip({required this.name, this.thumb});
  final String name;

  /// In-memory image/poster bytes (current session) — when present the bubble
  /// shows a real preview instead of a filename chip.
  final Uint8List? thumb;

  @override
  Widget build(BuildContext context) {
    final t = thumb;
    if (t != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          t,
          width: 160,
          height: 120,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _fileChip(),
        ),
      );
    }
    return _fileChip();
  }

  Widget _fileChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: JcTheme.glassBorder),
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

/// "Try on server" — shown under an on-device reply. Re-asks the same prompt on
/// the server (which can give a better answer); the local reply stays above.
class _TryServerButton extends StatelessWidget {
  const _TryServerButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_upload_outlined, size: 13, color: JcTheme.cyan),
          SizedBox(width: 4),
          Text('Try on server',
              style: TextStyle(
                  color: JcTheme.cyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
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

/// "1.2k in  ·  340 out  ·  12.4 s" — nothing more. Null when there's nothing to show.
String? _statusLine(ChatMessage m) {
  if (!m.isAssistant) return null;
  String fmtTok(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
  final parts = <String>[];
  final tilde = m.onDevice ? '~' : '';
  if (m.inputTokens != null || m.outputTokens != null) {
    parts.add('$tilde${fmtTok(m.inputTokens ?? 0)} in  ·  ${fmtTok(m.outputTokens ?? 0)} out');
  }
  final ms = m.durationMs;
  if (ms != null && ms > 0) {
    parts.add(ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '$ms ms');
  }
  if (m.onDevice) parts.insert(0, 'On-device');
  return parts.isEmpty ? null : parts.join('  ·  ');
}

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../chat_models.dart';

/// Collapsible card for a single tool call — mirrors the webui's
/// `.tool-card`. Collapsed by default, showing the tool name, a status
/// dot, and timing; expands to reveal arguments and any result.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.tool});

  final ToolInvocation tool;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tool = widget.tool;
    final running = !tool.done;
    final color = tool.isError
        ? JcTheme.danger
        : running
            ? JcTheme.blue
            : JcTheme.success;

    final hasDetail = tool.args.isNotEmpty ||
        (tool.result?.isNotEmpty ?? false) ||
        (tool.preview?.isNotEmpty ?? false);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: JcTheme.surface,
        border: Border.all(color: JcTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  if (running)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    )
                  else
                    Icon(
                      tool.isError ? Icons.error_outline : Icons.check_circle,
                      size: 14,
                      color: color,
                    ),
                  const SizedBox(width: 8),
                  const Icon(Icons.build_outlined, size: 13, color: JcTheme.muted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      tool.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (tool.durationSec != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${tool.durationSec!.toStringAsFixed(tool.durationSec! < 10 ? 1 : 0)}s',
                      style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                    ),
                  ],
                  if (hasDetail) ...[
                    const Spacer(),
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(Icons.chevron_right,
                          size: 16, color: JcTheme.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_open && hasDetail)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tool.args.isNotEmpty)
                    _CodeBox(label: 'Arguments', text: _pretty(tool.args)),
                  if ((tool.result ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _CodeBox(label: 'Result', text: tool.result!.trim()),
                  ] else if ((tool.preview ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _CodeBox(label: 'Result', text: tool.preview!.trim()),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _pretty(Map<String, dynamic> args) {
    try {
      return const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      return args.toString();
    }
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    // Keep long tool output from blowing out the message list.
    final clipped = text.length > 4000 ? '${text.substring(0, 4000)}\n…' : text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: JcTheme.muted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1830),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: JcTheme.border),
          ),
          child: SelectableText(
            clipped,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
              color: JcTheme.text,
            ),
          ),
        ),
      ],
    );
  }
}

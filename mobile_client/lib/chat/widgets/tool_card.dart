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

    final detail = tool.done
        ? ((tool.result ?? tool.preview ?? '').trim())
        : ((tool.preview ?? '').trim().isNotEmpty
            ? tool.preview!.trim()
            : _summariseArgs(tool.args));
    final firstLine = detail.split('\n').first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: hasDetail ? () => setState(() => _open = !_open) : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: running
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      )
                    : Icon(
                        tool.isError ? Icons.error_outline : Icons.check_circle,
                        size: 14,
                        color: tool.isError ? color : JcTheme.accent,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tool.label.replaceFirst('device_', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: JcTheme.text,
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (firstLine.isNotEmpty)
                      Text(
                        firstLine,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (tool.durationSec != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${tool.durationSec!.toStringAsFixed(tool.durationSec! < 10 ? 1 : 0)}s',
                  style: const TextStyle(color: JcTheme.muted, fontSize: 10.5),
                ),
              ],
            ],
          ),
        ),
        if (_open && hasDetail)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 6, 0, 4),
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
    );
  }

  /// One short line out of the arguments when the server sent no preview.
  static String _summariseArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final keys = args.keys.toList()..sort();
    return keys.take(3).map((k) {
      var v = '${args[k]}';
      if (v.length > 40) v = '${v.substring(0, 39)}…';
      return '$k: $v';
    }).join(' · ');
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

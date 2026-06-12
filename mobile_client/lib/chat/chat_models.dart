/// Data models for the native chat UI.
///
/// These mirror the webui's chat contract closely enough to render the
/// same conversation, but in a shape that's ergonomic for Flutter. An
/// assistant turn is an ordered list of [ChatBlock]s (text and tool
/// cards interleaved) plus a separate reasoning trace — exactly how the
/// webui lays out a streamed reply.
library;

import 'dart:convert';

/// A row in the sessions list (`GET /api/sessions`).
class ChatSessionSummary {
  ChatSessionSummary({
    required this.id,
    required this.title,
    this.messageCount,
    this.updatedAt,
    this.model,
    this.modelProvider,
    this.pinned = false,
    this.archived = false,
    this.isStreaming = false,
  });

  final String id;
  final String title;
  final int? messageCount;
  final int? updatedAt; // epoch seconds
  final String? model;
  final String? modelProvider;
  final bool pinned;
  final bool archived;
  final bool isStreaming;

  factory ChatSessionSummary.fromJson(Map<String, dynamic> j) {
    return ChatSessionSummary(
      id: (j['session_id'] ?? j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString().trim(),
      messageCount: _asInt(j['message_count']),
      updatedAt: _asInt(j['updated_at'] ?? j['last_message_at']),
      model: j['model']?.toString(),
      modelProvider: j['model_provider']?.toString(),
      pinned: j['pinned'] == true,
      archived: j['archived'] == true,
      isStreaming: j['is_streaming'] == true ||
          (j['active_stream_id'] != null &&
              j['active_stream_id'].toString().isNotEmpty),
    );
  }

  String get displayTitle => title.isEmpty ? 'New chat' : title;
}

/// One block inside a message. Assistant turns interleave [TextBlock]s
/// and [ToolBlock]s in arrival order.
sealed class ChatBlock {}

class TextBlock extends ChatBlock {
  TextBlock([this.text = '']);
  String text;
  bool get isEmpty => text.trim().isEmpty;
}

class ToolBlock extends ChatBlock {
  ToolBlock(this.tool);
  ToolInvocation tool;
}

/// A single tool call, used both live (streaming) and from history.
class ToolInvocation {
  ToolInvocation({
    required this.name,
    this.preview,
    Map<String, dynamic>? args,
    this.result,
    this.done = false,
    this.isError = false,
    this.durationSec,
    this.callId,
  }) : args = args ?? const {};

  String name;
  String? preview;
  Map<String, dynamic> args;
  String? result;
  bool done;
  bool isError;
  double? durationSec;
  String? callId;

  /// A short human label for the collapsed card header.
  String get label => name.replaceAll('_', ' ');
}

/// A chat message. User messages carry a single text block; assistant
/// messages carry interleaved blocks plus an optional reasoning trace.
class ChatMessage {
  ChatMessage({
    required this.role,
    List<ChatBlock>? blocks,
    this.reasoning = '',
    List<String>? attachments,
    this.streaming = false,
    this.isError = false,
    this.onDevice = false,
    this.ts,
  })  : blocks = blocks ?? <ChatBlock>[],
        attachments = attachments ?? const [];

  final String role; // user | assistant | system
  final List<ChatBlock> blocks;
  String reasoning;
  final List<String> attachments;
  bool streaming;
  bool isError;

  /// True when this assistant turn was answered/handled on-device (shows the
  /// "on-device" badge in the UI).
  bool onDevice;

  /// Per-turn status, shown as a small line under the reply ("Done in 3s ·
  /// 16k in · 12 out", or "On-device · 3s"). Set when the turn finishes.
  int? durationMs;
  int? inputTokens;
  int? outputTokens;

  final int? ts;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  /// Concatenated plain text — used for copy and the user-bubble path.
  String get plainText => blocks
      .whereType<TextBlock>()
      .map((b) => b.text)
      .where((t) => t.isNotEmpty)
      .join('\n\n');

  /// Append streamed text to the trailing text block, opening a fresh
  /// one if the last block is a tool card (post-tool continuation).
  void appendToken(String token) {
    if (blocks.isEmpty || blocks.last is! TextBlock) {
      blocks.add(TextBlock());
    }
    (blocks.last as TextBlock).text += token;
  }

  void startTool(ToolInvocation tool) {
    blocks.add(ToolBlock(tool));
  }

  /// Mark the most recent unfinished tool block as complete.
  void completeTool({
    String? name,
    double? durationSec,
    bool isError = false,
    String? preview,
  }) {
    for (final block in blocks.reversed) {
      if (block is ToolBlock && !block.tool.done) {
        if (name == null || block.tool.name == name) {
          block.tool.done = true;
          block.tool.durationSec = durationSec;
          block.tool.isError = isError;
          if (preview != null && preview.isNotEmpty) {
            block.tool.preview = preview;
          }
          return;
        }
      }
    }
  }

  factory ChatMessage.user(String text, {List<String>? attachments}) {
    return ChatMessage(
      role: 'user',
      blocks: [TextBlock(text)],
      attachments: attachments,
    );
  }

  /// Build a message from a stored session entry. Handles string or
  /// array `content`, OpenAI-style `tool_calls`, and a `thinking` /
  /// `reasoning` trace.
  static ChatMessage? fromStored(Map<String, dynamic> j) {
    final role = (j['role'] ?? '').toString();
    if (role == 'tool') return null; // folded into the matching tool block
    final blocks = <ChatBlock>[];
    final content = j['content'];
    if (content is String) {
      if (content.trim().isNotEmpty) blocks.add(TextBlock(content));
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        final type = (part['type'] ?? '').toString();
        if (type == 'text') {
          final t = (part['text'] ?? '').toString();
          if (t.isNotEmpty) blocks.add(TextBlock(t));
        } else if (type == 'tool_use') {
          blocks.add(ToolBlock(ToolInvocation(
            name: (part['name'] ?? 'tool').toString(),
            args: part['input'] is Map
                ? Map<String, dynamic>.from(part['input'] as Map)
                : const {},
            callId: part['id']?.toString(),
            done: true,
          )));
        }
      }
    }
    // OpenAI-style tool_calls live alongside content.
    final toolCalls = j['tool_calls'];
    if (toolCalls is List) {
      for (final tc in toolCalls) {
        if (tc is! Map) continue;
        final fn = tc['function'];
        final name = (fn is Map ? fn['name'] : tc['name'])?.toString() ?? 'tool';
        Map<String, dynamic> args = const {};
        if (fn is Map && fn['arguments'] is String) {
          args = _tryJsonMap(fn['arguments'] as String);
        } else if (fn is Map && fn['arguments'] is Map) {
          args = Map<String, dynamic>.from(fn['arguments'] as Map);
        }
        blocks.add(ToolBlock(ToolInvocation(
          name: name,
          args: args,
          callId: tc['id']?.toString(),
          done: true,
        )));
      }
    }
    final reasoning =
        (j['thinking'] ?? j['reasoning'] ?? '').toString();
    if (blocks.isEmpty && reasoning.isEmpty) return null;
    final attachments = <String>[];
    final att = j['attachments'];
    if (att is List) {
      for (final a in att) {
        if (a is Map && a['name'] != null) {
          attachments.add(a['name'].toString());
        } else if (a is String) {
          attachments.add(a);
        }
      }
    }
    return ChatMessage(
      role: role.isEmpty ? 'assistant' : role,
      blocks: blocks,
      reasoning: reasoning,
      attachments: attachments,
      onDevice: j['on_device'] == true,
      ts: _asInt(j['timestamp']),
    );
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

Map<String, dynamic> _tryJsonMap(String s) {
  try {
    final decoded = json.decode(s);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return const {};
}

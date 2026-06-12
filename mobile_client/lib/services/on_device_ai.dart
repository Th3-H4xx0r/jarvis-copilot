import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'on_device_ai_types.dart';

/// The minimal surface the [LocalRouter] depends on. Implemented by [OnDeviceAi]
/// (real platform channel) and by fakes in tests.
abstract interface class OnDeviceAiClient {
  Future<OnDeviceAvailability> availability();
  Future<RoutingDecision> route(LocalRequest req);
  Stream<String> generate(LocalRequest req);
}

/// Dart wrapper around the native on-device inference engines (Apple
/// Foundation Models + MLX). Inference happens in Swift; this class only
/// marshals requests and demuxes the streaming EventChannel by requestId.
///
/// Everything degrades gracefully: if the native side is missing (e.g. running
/// on a build without the engine wired, or Android), calls resolve to
/// "unavailable" / escalate rather than throwing.
class OnDeviceAi implements OnDeviceAiClient {
  OnDeviceAi._();
  static final OnDeviceAi instance = OnDeviceAi._();

  static const MethodChannel _method =
      MethodChannel('jarviscopilot/ondevice-ai');
  static const EventChannel _events =
      EventChannel('jarviscopilot/ondevice-ai/stream');

  Stream<Map<String, dynamic>>? _stream;
  int _seq = 0;

  /// The server's active JARVIS personality/system prompt, so on-device replies
  /// speak in the same voice as the server. Populated at startup (and on
  /// refresh) from GET /api/personality/active. Empty = no persona configured.
  String persona = '';

  void setPersona(String p) => persona = p.trim();

  Stream<Map<String, dynamic>> get _eventStream {
    return _stream ??= _events
        .receiveBroadcastStream()
        .map((e) => _asMap(e))
        .asBroadcastStream();
  }

  String _nextRequestId() =>
      'req-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  // ── Availability ──────────────────────────────────────────────────────────

  @override
  Future<OnDeviceAvailability> availability() async {
    try {
      final res = await _method.invokeMethod('availability');
      return OnDeviceAvailability.fromJson(_asMap(res));
    } on MissingPluginException {
      return OnDeviceAvailability.unavailable('no-native-engine');
    } catch (e) {
      return OnDeviceAvailability.unavailable('availability-error: $e');
    }
  }

  // ── Routing (one-shot structured decision) ────────────────────────────────

  @override
  Future<RoutingDecision> route(LocalRequest req) async {
    try {
      final res = await _method.invokeMethod('route', {
        'system': _buildRoutingPrompt(req),
        'prompt': req.userText,
        'schema': _routingSchemaJson,
        'requestId': _nextRequestId(),
      });
      return RoutingDecision.fromJson(_asMap(res));
    } on MissingPluginException {
      return RoutingDecision.escalate('no-native-engine');
    } catch (e) {
      return RoutingDecision.escalate('route-error: $e');
    }
  }

  // ── Streaming generation (used by full-local-first long answers) ───────────

  @override
  Stream<String> generate(LocalRequest req) {
    final requestId = _nextRequestId();
    final controller = StreamController<String>();
    StreamSubscription<Map<String, dynamic>>? sub;

    void finish() {
      sub?.cancel();
      sub = null;
      if (!controller.isClosed) controller.close();
    }

    controller.onCancel = () {
      finish();
      cancel(requestId);
    };

    sub = _eventStream.where((e) => e['requestId'] == requestId).listen((e) {
      final type = (e['type'] ?? '').toString();
      switch (type) {
        case 'token':
          final t = (e['text'] ?? '').toString();
          if (t.isNotEmpty) controller.add(t);
          break;
        case 'done':
          finish();
          break;
        case 'error':
          controller.addError(StateError((e['text'] ?? 'generate error').toString()));
          finish();
          break;
      }
    });

    _method.invokeMethod('generate', {
      'system': _buildAssistantPrompt(),
      'prompt': req.userText,
      'requestId': requestId,
    }).catchError((e) {
      controller.addError(e);
      finish();
      return null;
    });

    return controller.stream;
  }

  Future<void> cancel(String requestId) async {
    try {
      await _method.invokeMethod('cancel', {'requestId': requestId});
    } catch (_) {}
  }

  // ── On-device STT (Apple Speech) for the voice local front-path ────────────

  /// Transcribe a PCM16-LE mono buffer on-device. Returns '' if on-device STT
  /// isn't available (older OS / no permission / no native engine) so the
  /// caller falls back to the server's STT.
  Future<String> transcribe(List<int> pcm, {int sampleRate = 16000}) async {
    try {
      final res = await _method.invokeMethod('transcribe', {
        'pcm': Uint8List.fromList(pcm),
        'sample_rate': sampleRate,
      });
      return (res ?? '').toString();
    } on MissingPluginException {
      return '';
    } catch (e) {
      debugPrint('[ondevice] transcribe failed: $e');
      return '';
    }
  }

  // ── Model management (used by the Settings UI, not the router) ─────────────

  Future<List<LocalModelInfo>> listModels() async {
    try {
      final res = await _method.invokeMethod('listModels');
      if (res is List) {
        return res.map((e) => LocalModelInfo.fromJson(_asMap(e))).toList();
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Download a model; emits progress 0.0..1.0, completes on done.
  Stream<double> downloadModel(String id) {
    final controller = StreamController<double>();
    StreamSubscription<Map<String, dynamic>>? sub;
    void finish() {
      sub?.cancel();
      sub = null;
      if (!controller.isClosed) controller.close();
    }

    controller.onCancel = () {
      finish();
      cancelDownload(id);
    };
    sub = _eventStream.where((e) => e['requestId'] == id).listen((e) {
      final type = (e['type'] ?? '').toString();
      switch (type) {
        case 'progress':
          final v = e['value'];
          if (v is num) controller.add(v.toDouble());
          break;
        case 'done':
          controller.add(1.0);
          finish();
          break;
        case 'error':
          controller.addError(
              StateError((e['text'] ?? 'download error').toString()));
          finish();
          break;
      }
    });
    _method.invokeMethod('downloadModel', {'id': id}).catchError((e) {
      controller.addError(e);
      finish();
      return null;
    });
    return controller.stream;
  }

  Future<void> cancelDownload(String id) async {
    try {
      await _method.invokeMethod('cancelDownload', {'id': id});
    } catch (_) {}
  }

  Future<void> deleteModel(String id) async {
    try {
      await _method.invokeMethod('deleteModel', {'id': id});
    } catch (_) {}
  }

  Future<void> loadModel(String id) async {
    try {
      await _method.invokeMethod('loadModel', {'id': id});
    } catch (_) {}
  }

  // ── Prompt construction (kept here so prompt engineering lives in one place) ─

  static const String _routingSchemaJson =
      '{"action":"answer|tool|escalate","answer":"string?","toolName":"string?",'
      '"toolArgs":{},"confidence":0.0,"reason":"string?"}';

  /// Plain assistant prompt for free-form generation (the debug Test box and
  /// full-local-first streamed answers). Leads with the server persona so the
  /// on-device reply sounds like the same JARVIS. NOT the router prompt — that
  /// one tells the model to emit a decision object.
  String _buildAssistantPrompt() {
    const base =
        'Answer the user directly and briefly in plain text. Do not output '
        'JSON, tool calls, or meta-commentary — just the reply.';
    return persona.isEmpty
        ? 'You are JARVIS, a concise and helpful on-device assistant. $base'
        : '$persona\n\n$base';
  }

  String _buildRoutingPrompt(LocalRequest req) {
    final tierPolicy = switch (req.tier) {
      LocalAiTier.fullLocalFirst =>
        'You may fully answer the user and may call tools (device-local AND '
            'client-dispatchable). Escalate only when you need fresh world '
            'knowledge, multi-step server reasoning, or a server-only tool.',
      LocalAiTier.routerCommands =>
        'Only answer trivial, safe, self-contained turns (greetings, quick '
            'rephrase/summarize of given text, simple device questions). For a '
            'clear device action, emit a tool call. Escalate ANYTHING else.',
      LocalAiTier.off => 'Escalate everything.',
    };
    final surface = req.surface == VoiceSurface.voice ? 'voice' : 'chat';
    final personaLine = persona.isEmpty ? '' : '$persona\n\n';
    return '''
${personaLine}You are JARVIS, deciding how to handle a $surface turn. Choose ONE "action":
- "answer": you can handle this yourself (greetings, chit-chat, identity/"what model are you", quick facts you know, rephrase/summarize given text). ALWAYS write the full reply, in JARVIS's voice, in "answer".
- "tool": the user clearly wants an action that maps to one tool below. Set "toolName" + "toolArgs", AND put a short spoken confirmation in JARVIS's voice in "answer" (e.g. "Opening Spotify for you, sir.").
- "escalate": ONLY for things you genuinely cannot do — fresh/live facts, the user's accounts or private data, multi-step reasoning, or a server-only tool. Greetings and identity questions are NOT escalate.

Default to "answer" for anything conversational. Policy: $tierPolicy
Set "confidence" 0..1. Return ONLY the decision object: $_routingSchemaJson

Available tools (name · description · execClass):
${req.toolCatalogJson}
''';
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map) {
      return v.map((k, value) => MapEntry(k.toString(), value));
    }
    if (v is String && v.isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is Map) {
          return decoded.map((k, value) => MapEntry(k.toString(), value));
        }
      } catch (_) {}
    }
    if (v != null) {
      debugPrint('[ondevice] unexpected channel payload: ${v.runtimeType}');
    }
    return <String, dynamic>{};
  }
}

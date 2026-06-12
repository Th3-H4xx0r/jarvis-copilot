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
    final surface = req.surface == VoiceSurface.voice ? 'voice' : 'chat';
    // NOTE: deliberately persona-FREE. The persona ("you are JARVIS, at your
    // service…") biases the model to answer everything in character — it must
    // not leak into the routing DECISION. Persona is applied only when we
    // generate the actual reply text (see _buildAssistantPrompt).
    return '''
You are a strict request CLASSIFIER for an on-device phone assistant. This is NOT a chat — do NOT role-play or answer the user. Output ONLY a decision object.

Pick "action":
- "escalate" (THE DEFAULT): anything needing real-world or live data (weather, news, time/date, prices, sports, traffic), the user's own data or accounts (calendar, email, messages, reminders, files, anything "my ...", a "morning brief"), or any task beyond a plain reply or one of the device actions listed. If answering it would require knowing real facts you can't be certain of, escalate. Put "" in "answer".
- "answer": ONLY greetings/small-talk, questions about the assistant itself ("who are you", "what can you do"), or rephrasing/summarizing text the user already gave you. Put a short reply in "answer".
- "tool": the user clearly wants one of the device actions listed below. Set "toolName" + "toolArgs", and a one-line confirmation in "answer".

escalate examples: "give me the morning brief", "what's the weather", "what's on my calendar", "any news?", "what time is it", "text mom".
answer examples: "hello", "who are you", "what can you do", "summarize this: ...".

When in doubt, ESCALATE. Set "confidence" 0..1. Return ONLY: $_routingSchemaJson

Device actions you can trigger on $surface (name · description):
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

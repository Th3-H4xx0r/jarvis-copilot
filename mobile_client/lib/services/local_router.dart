import 'dart:async';

import 'package:flutter/foundation.dart';

import 'local_ai_settings.dart';
import 'local_tool_catalog.dart';
import 'on_device_ai.dart';
import 'on_device_ai_types.dart';

/// Decides, for one user turn, whether the on-device model handles it (answer
/// or local tool call) or whether to escalate to the server. The router NEVER
/// touches the network — it returns a [RouteResult]; the caller acts on it.
///
/// Fail-safe by construction: tier off, surface disabled, engine unavailable,
/// timeout, low confidence, parse failure, or any error all resolve to
/// [Escalate] so the server path is never blocked.
class LocalRouter {
  LocalRouter({
    OnDeviceAiClient? ai,
    ToolCatalog? catalog,
    LocalAiSettings? settings,
  })  : _ai = ai ?? OnDeviceAi.instance,
        _catalog = catalog ?? LocalToolCatalog(),
        _settings = settings ?? LocalAiSettings.instance;

  final OnDeviceAiClient _ai;
  final ToolCatalog _catalog;
  final LocalAiSettings _settings;

  Future<RouteResult> handle(String userText, VoiceSurface surface) async {
    final text = userText.trim();
    if (text.isEmpty) return const Escalate('empty-input');

    // 1. Tier / per-surface gate (zero added latency).
    if (_settings.tier == LocalAiTier.off) return const Escalate('tier-off');
    if (!_settings.enabledFor(surface)) {
      return Escalate('${surface.name}-disabled');
    }

    // 2. Engine availability.
    final avail = await _ai.availability();
    if (!avail.available) {
      return Escalate('unavailable:${avail.reason ?? 'unknown'}');
    }

    // 3. One-shot structured decision under a hard deadline.
    RoutingDecision dec;
    try {
      final catalogJson = await _catalog.buildPromptCatalog();
      final req = LocalRequest(
        userText: text,
        surface: surface,
        toolCatalogJson: catalogJson,
        tier: _settings.tier,
      );
      dec = await _ai
          .route(req)
          .timeout(Duration(milliseconds: _settings.deadlineMs));
    } on TimeoutException {
      return const Escalate('timeout');
    } catch (e) {
      debugPrint('[router] route error: $e');
      return Escalate('error:$e');
    }

    // 4. Map the decision.
    return _interpret(dec);
  }

  RouteResult _interpret(RoutingDecision dec) {
    switch (dec.action) {
      case 'escalate':
        return Escalate(dec.reason ?? 'model-escalate');

      case 'answer':
        if (dec.confidence < _settings.confidenceFloor) {
          return const Escalate('low-confidence');
        }
        final answer = (dec.answer ?? '').trim();
        if (answer.isEmpty) return const Escalate('empty-answer');
        return DirectAnswer(answer);

      case 'tool':
        final name = (dec.toolName ?? '').trim();
        if (name.isEmpty) return const Escalate('no-tool-name');
        final cls = _catalog.classOf(name);
        // serverOnly always escalates.
        if (cls == ToolExecClass.serverOnly) return const Escalate('server-tool');
        // client-dispatchable tools require the full-local-first tier; the
        // baseline tier only fires device-local commands.
        if (cls == ToolExecClass.clientDispatchable &&
            _settings.tier != LocalAiTier.fullLocalFirst) {
          return const Escalate('client-tool-needs-full-tier');
        }
        if (dec.confidence < _settings.confidenceFloor) {
          return const Escalate('low-confidence');
        }
        return ToolCall(name, dec.toolArgs, cls);

      default:
        return Escalate('unknown-action:${dec.action}');
    }
  }
}

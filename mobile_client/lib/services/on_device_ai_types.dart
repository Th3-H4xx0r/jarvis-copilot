/// Shared types for the on-device AI layer (Approach A: Dart orchestrates,
/// native engines do inference). These are the locked interfaces every part
/// of the feature aligns to — the router, the channel wrapper, the catalog,
/// and the chat/voice integrations all speak in these terms.
library;

/// How aggressively the on-device layer handles a turn before escalating.
enum LocalAiTier {
  /// Everything goes to the server (today's behavior).
  off,

  /// Local model answers trivial/safe turns + fires device-local skills;
  /// everything else escalates.
  routerCommands,

  /// Local model also attempts client-dispatchable tool calls and streams
  /// longer local answers; only server-only work + low-confidence escalate.
  fullLocalFirst,
}

extension LocalAiTierCodec on LocalAiTier {
  String get wire => switch (this) {
        LocalAiTier.off => 'off',
        LocalAiTier.routerCommands => 'router_commands',
        LocalAiTier.fullLocalFirst => 'full_local_first',
      };

  static LocalAiTier parse(String? s) => switch (s) {
        'router_commands' => LocalAiTier.routerCommands,
        'full_local_first' => LocalAiTier.fullLocalFirst,
        _ => LocalAiTier.off,
      };
}

/// Where a tool actually runs — decides whether the client can execute it
/// locally or must escalate to the server agent.
enum ToolExecClass {
  /// Phone/watch runs it themselves; works fully offline + instant.
  deviceLocal,

  /// The app's InvokeRunner can dispatch it (may hop the bridge to another
  /// device) — needs network but not the server agent.
  clientDispatchable,

  /// Must be run by the server agent.
  serverOnly,
}

/// Which app surface a turn came from.
enum VoiceSurface { chat, voice }

/// The structured decision the local model returns.
class RoutingDecision {
  RoutingDecision({
    required this.action,
    this.answer,
    this.toolName,
    this.toolArgs = const {},
    this.confidence = 0.0,
    this.reason,
  });

  /// 'answer' | 'tool' | 'escalate'
  final String action;
  final String? answer;
  final String? toolName;
  final Map<String, dynamic> toolArgs;
  final double confidence;
  final String? reason;

  factory RoutingDecision.fromJson(Map<String, dynamic> j) => RoutingDecision(
        action: (j['action'] ?? 'escalate').toString(),
        answer: j['answer']?.toString(),
        toolName: j['toolName']?.toString(),
        toolArgs: j['toolArgs'] is Map
            ? Map<String, dynamic>.from(j['toolArgs'] as Map)
            : const {},
        confidence:
            (j['confidence'] is num) ? (j['confidence'] as num).toDouble() : 0.0,
        reason: j['reason']?.toString(),
      );

  static RoutingDecision escalate(String reason) =>
      RoutingDecision(action: 'escalate', reason: reason);
}

/// What the router tells the caller (ChatController / VoiceController) to do.
sealed class RouteResult {
  const RouteResult();
}

/// Speak/show this text — generated on-device.
class DirectAnswer extends RouteResult {
  const DirectAnswer(this.text);
  final String text;
}

/// Execute this tool locally (via InvokeRunner). When [requiresConfirm] is
/// true the action is outward-facing/destructive and the caller should confirm
/// (chat) / ask aloud (voice) before running it.
class ToolCall extends RouteResult {
  const ToolCall(this.name, this.args, this.execClass,
      {this.requiresConfirm = false, this.confirmation});
  final String name;
  final Map<String, dynamic> args;
  final ToolExecClass execClass;
  final bool requiresConfirm;

  /// A short natural confirmation in JARVIS's voice (from the model), shown/
  /// spoken instead of a flat "Done." when present.
  final String? confirmation;
}

/// Hand off to the server path with this reason (for logs/telemetry).
class Escalate extends RouteResult {
  const Escalate(this.reason);
  final String reason;
}

/// A single inference request handed to the native engine.
class LocalRequest {
  LocalRequest({
    required this.userText,
    required this.surface,
    required this.toolCatalogJson,
    required this.tier,
  });

  final String userText;
  final VoiceSurface surface;

  /// Serialized tool catalog the model sees (name, 1-line desc, execClass).
  final String toolCatalogJson;
  final LocalAiTier tier;
}

/// Metadata for one available local model (Apple FM or a downloadable one).
class LocalModelInfo {
  LocalModelInfo({
    required this.id,
    required this.label,
    required this.engine,
    required this.installed,
    this.sizeBytes,
    this.ramHintMb,
  });

  final String id;
  final String label;

  /// 'apple-fm' | 'mlx'
  final String engine;
  final bool installed;
  final int? sizeBytes;
  final int? ramHintMb;

  factory LocalModelInfo.fromJson(Map<String, dynamic> j) => LocalModelInfo(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? j['id'] ?? '').toString(),
        engine: (j['engine'] ?? 'mlx').toString(),
        installed: j['installed'] == true,
        sizeBytes: (j['sizeBytes'] is num)
            ? (j['sizeBytes'] as num).toInt()
            : null,
        ramHintMb:
            (j['ramHintMb'] is num) ? (j['ramHintMb'] as num).toInt() : null,
      );
}

/// Engine availability snapshot from the native side.
class OnDeviceAvailability {
  OnDeviceAvailability({
    required this.available,
    required this.engine,
    this.reason,
  });

  final bool available;
  final String engine;
  final String? reason;

  factory OnDeviceAvailability.fromJson(Map<String, dynamic> j) =>
      OnDeviceAvailability(
        available: j['available'] == true,
        engine: (j['engine'] ?? 'apple-fm').toString(),
        reason: j['reason']?.toString(),
      );

  static OnDeviceAvailability unavailable(String reason) =>
      OnDeviceAvailability(available: false, engine: 'none', reason: reason);
}

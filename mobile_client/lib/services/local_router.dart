import 'local_ai_settings.dart';
import 'local_command_matcher.dart';
import 'local_executor.dart';
import 'on_device_ai.dart';
import 'on_device_ai_types.dart';

/// Decides, for one user turn, whether the on-device model answers it or whether
/// to escalate to the server. The router never touches the network — it returns
/// a [RouteResult]; the caller acts on it.
///
/// Design (fast + reliable): the on-device model is used ONLY to ANSWER
/// conversation/knowledge — the one thing a small model does well and fast (one
/// streamed inference, like the standalone Apple-model apps). A cheap keyword
/// PRE-GATE sends everything else (device commands, live data, the user's
/// accounts, sending/calling/playing) to the server, where tool execution
/// actually works. No guided-generation routing call, so there's only ONE model
/// inference per local turn.
class LocalRouter {
  LocalRouter({
    OnDeviceAiClient? ai,
    LocalAiSettings? settings,
  })  : _ai = ai ?? OnDeviceAi.instance,
        _settings = settings ?? LocalAiSettings.instance;

  final OnDeviceAiClient _ai;
  final LocalAiSettings _settings;

  Future<RouteResult> handle(String userText, VoiceSurface surface) async {
    final text = userText.trim();
    if (text.isEmpty) return const Escalate('empty-input');

    // Tier / per-surface gate (zero added latency).
    if (_settings.tier == LocalAiTier.off) return const Escalate('tier-off');
    if (!_settings.enabledFor(surface)) {
      return Escalate('${surface.name}-disabled');
    }

    // Engine availability.
    final avail = await _ai.availability();
    if (!avail.available) {
      return Escalate('unavailable:${avail.reason ?? 'unknown'}');
    }

    // Device-local action with a safety allow-list (plan 4.3 / 4.5). Checked
    // FIRST: it knows which skills this device actually has, refuses anything
    // off the allow-list, and covers more verbs (alarms, clipboard, camera,
    // URLs) than the older matcher. Anything it doesn't recognise falls
    // through, so previous behaviour is unchanged.
    final local = LocalExecutor.classify(text);
    if (local is LocalRun) {
      return ToolCall(local.skill, local.args, ToolExecClass.deviceLocal,
          confirmation: local.ack);
    }

    // Instant local command (deterministic, no model) for simple, reliable,
    // this-device actions — open an app, flashlight, vibrate, volume. These run
    // immediately via the existing skill; no model means no fabricated args.
    final cmd = LocalCommandMatcher.match(text);
    if (cmd != null) {
      return ToolCall(cmd.name, cmd.args, ToolExecClass.deviceLocal,
          confirmation: cmd.confirmation);
    }

    // Pre-gate: anything that needs to DO something or fetch real data goes to
    // the server (the small on-device model fabricates args / role-plays these,
    // and the server has the working skills + the user's data). The local model
    // only answers conversation/knowledge.
    if (looksLikeServerRequest(text)) return const Escalate('server-request');

    // Answer locally — the caller streams a full reply from the model.
    return const DirectAnswer('');
  }

  /// True when the turn looks like a command, an outward action, or a request
  /// for live/real-world or account data — i.e. something the on-device model
  /// can't reliably do and that belongs on the server.
  static bool looksLikeServerRequest(String text) =>
      _serverRequestRe.hasMatch(text);

  static final RegExp _serverRequestRe = RegExp(
    r'\b('
    // outward comms
    r'text|sms|send|email|e-?mail|call|dial|message|msg|dm|tweet|whatsapp|imessage|'
    // media / apps / navigation
    r'play|pause|skip|stream|spotify|youtube|open|launch|navigate|directions?|maps?|uber|'
    // create / schedule / device control
    r'set|turn|switch|toggle|remind|reminders?|schedule|alarm|timer|vibrate|flashlight|torch|'
    r'brightness|volume|wifi|bluetooth|airplane|dnd|book|reserve|order|buy|purchase|pay|'
    r'add|create|delete|remove|search|google|find|look ?up|translate|download|install|'
    // live data / accounts / "my ..."
    r'weather|forecast|temperature|news|headlines?|stocks?|prices?|traffic|scores?|sports?|'
    r'calendar|agenda|inbox|emails?|meetings?|tasks?|notes?|brief|flights?|'
    r'my'
    r')\b',
    caseSensitive: false,
  );
}

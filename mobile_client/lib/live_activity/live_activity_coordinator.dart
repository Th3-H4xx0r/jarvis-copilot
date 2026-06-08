import 'dart:async';

import 'package:flutter/services.dart';

import '../api/coding_sessions.dart';
import '../coding/coding_models.dart';
import '../services/app_lifecycle.dart';
import '../services/credentials.dart';

/// Thin channel wrapper to the native `LiveActivityManager` (AppDelegate).
/// `update` takes the full merged arg map the coordinator builds; `end` tears
/// the activity down. Both are fire-and-forget and swallow channel errors.
class LiveActivity {
  static const _ch = MethodChannel('jarviscopilot/liveactivity');
  static void update(Map<String, dynamic> args) =>
      unawaited(_ch.invokeMethod<void>('update', args).catchError((_) {}));
  static void end() =>
      unawaited(_ch.invokeMethod<void>('end').catchError((_) {}));
}

/// The SINGLE owner of the JARVIS Live Activity. Voice and coding both report
/// to it; it picks the mode (voice wins while a turn is live, otherwise the
/// coding fleet shows when there are live sessions), builds the merged
/// `ContentState` args, dedupes, and pushes to the native side.
///
/// This replaces VoiceController pushing the channel directly — having two
/// independent pushers over one activity was the dueling-pusher bug class.
class LiveActivityCoordinator {
  LiveActivityCoordinator(this._api) {
    instance = this;
  }

  /// Set in the constructor so VoiceController can reach the coordinator without
  /// an import cycle (`LiveActivityCoordinator.instance?.reportVoice(...)`).
  static LiveActivityCoordinator? instance;

  final CodingSessionsApi _api;

  bool _enabled = true;
  Timer? _poll;
  static const Duration _pollInterval = Duration(seconds: 5);

  // ── last voice snapshot ──
  String _voiceState = 'idle';
  String _voiceTranscript = '';
  String _voiceActivity = '';
  bool _connected = true;
  List<String> _devices = const [];

  // ── last coding snapshot ──
  List<String> _sessions = const []; // "name\u{1f}state", ≤4, spotlight-sorted
  int _sessionTotal = 0;
  int _waitingCount = 0;
  int _usage5 = -1;
  int _usageWeek = -1;
  String _usage5Resets = '';
  String _usageWeekResets = '';

  String _lastSig = '';

  // ── lifecycle ──

  /// Begin coordinating (called once from main()). No-op (and no activity) when
  /// the user has disabled Live Activities in settings.
  void start() {
    _enabled = Credentials.instance.liveActivitiesEnabled;
    if (!_enabled) return;
    _startPoll();
    unawaited(_refreshCoding());
  }

  /// Settings toggle. Off → end the activity + stop polling; on → resume.
  void setEnabled(bool on) {
    _enabled = on;
    if (on) {
      _startPoll();
      unawaited(_refreshCoding());
    } else {
      _stopPoll();
      _lastSig = '';
      LiveActivity.end();
    }
  }

  /// App came to the foreground — refresh coding state and re-push.
  void onResume() {
    if (!_enabled) return;
    _startPoll();
    unawaited(_refreshCoding());
  }

  /// VoiceController reports its state here (instead of pushing the channel).
  void reportVoice({
    required String state,
    String transcript = '',
    String activity = '',
    required bool connected,
    List<String> devices = const [],
  }) {
    _voiceState = state;
    _voiceTranscript = transcript;
    _voiceActivity = activity;
    _connected = connected;
    _devices = devices;
    _push();
  }

  // ── coding poll ──

  void _startPoll() {
    _stopPoll();
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!_enabled || !AppLifecycle.isForeground) return;
      unawaited(_refreshCoding());
    });
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _refreshCoding() async {
    try {
      final res = await _api.listSessionsWithUsage();
      _applyCoding(res.sessions, res.usage);
      _push();
    } catch (_) {
      // transient — keep the last snapshot, retry next tick
    }
  }

  static int _statePriority(String s) {
    switch (s) {
      case 'waiting':
        return 0;
      case 'working':
        return 1;
      default:
        return 2; // idle
    }
  }

  void _applyCoding(List<CodingSession> all, Map<String, dynamic>? usage) {
    final live =
        all.where((s) => s.isLive && !s.isTranscriptIdle).toList(growable: false)
          ..sort((a, b) {
            final pa = _statePriority(a.liveState);
            final pb = _statePriority(b.liveState);
            if (pa != pb) return pa - pb;
            return b.recencyTs.compareTo(a.recencyTs); // newer first within a tier
          });
    _sessionTotal = live.length;
    _waitingCount = live.where((s) => s.liveState == 'waiting').length;
    _sessions = live
        .take(4)
        .map((s) => '${_sanitize(s.displayTitle)}\u{1f}${s.liveState}')
        .toList(growable: false);
    if (usage != null) {
      _usage5 = _asInt(usage['five_hour_pct'], -1);
      _usageWeek = _asInt(usage['weekly_pct'], -1);
      _usage5Resets = (usage['five_hour_resets'] ?? '').toString();
      _usageWeekResets = (usage['weekly_resets'] ?? '').toString();
    }
  }

  // ── push ──

  void _push() {
    if (!_enabled) return;
    final voiceActive = _voiceState != 'idle';
    final mode = voiceActive
        ? 'voice'
        : (_sessionTotal > 0 ? 'coding' : 'voice');
    final coding = mode == 'coding';
    final args = <String, dynamic>{
      'state': _voiceState,
      'transcript': _voiceTranscript,
      'activity': _voiceActivity,
      'connected': _connected,
      'devices': _devices,
      'mode': mode,
      'sessions': coding ? _sessions : const <String>[],
      'sessionTotal': coding ? _sessionTotal : 0,
      'waitingCount': coding ? _waitingCount : 0,
      'usage5': coding ? _usage5 : -1,
      'usageWeek': coding ? _usageWeek : -1,
      'usage5Resets': coding ? _usage5Resets : '',
      'usageWeekResets': coding ? _usageWeekResets : '',
    };
    final sig = _signature(args);
    if (sig == _lastSig) return; // nothing changed → don't churn the activity
    _lastSig = sig;
    LiveActivity.update(args);
  }

  static String _signature(Map<String, dynamic> a) => [
        a['state'],
        a['transcript'],
        a['activity'],
        a['connected'],
        (a['devices'] as List).join(','),
        a['mode'],
        (a['sessions'] as List).join('|'),
        a['sessionTotal'],
        a['waitingCount'],
        a['usage5'],
        a['usageWeek'],
        a['usage5Resets'],
        a['usageWeekResets'],
      ].join('§');

  static String _sanitize(String s) {
    var t = s.replaceAll('\u{1f}', ' ').trim();
    if (t.length > 22) t = '${t.substring(0, 21)}…';
    return t;
  }

  static int _asInt(dynamic v, int dflt) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? dflt;
    return dflt;
  }
}

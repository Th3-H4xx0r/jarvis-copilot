import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

  /// Native pushes the per-activity APNs token here (for push-to-update).
  static void setPushTokenHandler(void Function(String token) cb) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'laPushToken') {
        final args = call.arguments;
        final t = (args is Map ? (args['token'] ?? '') : '').toString();
        if (t.isNotEmpty) cb(t);
      }
      return null;
    });
  }
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
    // Receive the per-activity APNs push token from native and register it so
    // the server can push-to-update the activity while the app is suspended.
    LiveActivity.setPushTokenHandler(_onPushToken);
  }

  String _lastToken = '';

  void _onPushToken(String token) {
    if (token == _lastToken) return; // tokens rotate; only register changes
    _lastToken = token;
    unawaited(_api
        .registerLaToken(token, deviceId: Credentials.instance.deviceId)
        .catchError((_) {}));
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
  int _sessionTotal = 0; // total live sessions (header "N sessions")
  int _entryTotal = 0; // total legend rows = projects + ungrouped ("+N more")
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

  DateTime _lastBgPoll = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _bgPollInterval = Duration(seconds: 30);

  void _startPoll() {
    _stopPoll();
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!_enabled) return;
      if (AppLifecycle.isForeground) {
        unawaited(_refreshCoding());
        return;
      }
      // Backgrounded: this only fires while the app is still ALIVE in the
      // background (a location/audio background mode keeps it running; otherwise
      // iOS suspends it and the timer is frozen). Poll less often to save
      // battery, so the Live Activity still auto-updates while the app lives.
      // For true always-live updates with the app fully suspended/closed, an
      // APNs push-to-update path is required (not built — foreground-driven v1).
      final now = DateTime.now();
      if (now.difference(_lastBgPoll) >= _bgPollInterval) {
        _lastBgPoll = now;
        unawaited(_refreshCoding());
      }
    });
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _refreshCoding() async {
    if (!Credentials.instance.isPaired) return; // nothing to fetch yet
    try {
      final view = await _api.listProjectsExpanded();
      final usage = await _api.getUsage();
      _applyFleet(view, usage);
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

  void _applyFleet(CodingProjectsView view, Map<String, dynamic>? usage) {
    // One legend row per PROJECT (aggregate state), labeled by the project name
    // (a repo/folder) — NOT the session title, which can be a transcript
    // artifact like "<local-command-stdout>". Ungrouped sessions fall back to
    // their folder name.
    final entries =
        <({String label, String state, double recency, List<String> subs})>[];
    var total = 0;
    var waiting = 0;
    for (final p in view.projects) {
      final live = p.sessions
          .where((s) => s.isLive && !s.isTranscriptIdle)
          .toList(growable: false);
      if (live.isEmpty) continue;
      total += live.length;
      waiting += live.where((s) => s.liveState == 'waiting').length;
      // Per-session sub-states ordered waiting>working>idle (for the split bar).
      final subs = live.map((s) => s.liveState).toList()
        ..sort((a, b) => _statePriority(a) - _statePriority(b));
      entries.add((
        label: p.name,
        state: _aggregateState(live),
        recency: live.map((s) => s.recencyTs).reduce(max),
        subs: subs.take(8).toList(growable: false),
      ));
    }
    for (final s
        in view.ungrouped.where((s) => s.isLive && !s.isTranscriptIdle)) {
      total += 1;
      if (s.liveState == 'waiting') waiting += 1;
      entries.add((
        label: _folderName(s),
        state: s.liveState,
        recency: s.recencyTs,
        subs: [s.liveState],
      ));
    }
    entries.sort((a, b) {
      final pa = _statePriority(a.state);
      final pb = _statePriority(b.state);
      if (pa != pb) return pa - pb;
      return b.recency.compareTo(a.recency); // newer first within a tier
    });
    _sessionTotal = total;
    _entryTotal = entries.length;
    _waitingCount = waiting;
    // Encode "name␟aggState[␟subs]" — the 3rd field (per-session sub-states,
    // e.g. "p,w") is added only for a project with 2+ live sessions, so a
    // single-session row renders as one solid segment (unchanged).
    _sessions = entries.take(4).map((e) {
      var enc = '${_sanitize(e.label)}\u{1f}${e.state}';
      if (e.subs.length > 1) enc += '\u{1f}${_encodeSubs(e.subs)}';
      return enc;
    }).toList(growable: false);
    if (usage != null) {
      _usage5 = _asInt(usage['five_hour_pct'], -1);
      _usageWeek = _asInt(usage['weekly_pct'], -1);
      _usage5Resets = (usage['five_hour_resets'] ?? '').toString();
      _usageWeekResets = (usage['weekly_resets'] ?? '').toString();
    }
  }

  static String _aggregateState(List<CodingSession> live) {
    if (live.any((s) => s.liveState == 'waiting')) return 'waiting';
    if (live.any((s) => s.liveState == 'working')) return 'working';
    return 'idle';
  }

  static const Map<String, String> _shortState = {
    'working': 'w',
    'waiting': 'p',
    'idle': 'i',
  };

  static String _encodeSubs(List<String> subs) =>
      subs.take(8).map((s) => _shortState[s] ?? 'i').join(',');

  static String _folderName(CodingSession s) {
    final cwd = (s.cwd ?? '').trim();
    if (cwd.isNotEmpty) {
      final base = cwd.replaceAll(RegExp(r'/+$'), '').split('/').last;
      if (base.isNotEmpty) return base;
    }
    return 'session';
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
      'entryTotal': coding ? _entryTotal : 0,
      'waitingCount': coding ? _waitingCount : 0,
      'usage5': coding ? _usage5 : -1,
      'usageWeek': coding ? _usageWeek : -1,
      'usage5Resets': coding ? _usage5Resets : '',
      'usageWeekResets': coding ? _usageWeekResets : '',
    };
    // Collision-proof dedupe: encode the structured args (a session title with a
    // delimiter char can't fake-match like a join() would).
    final sig = jsonEncode(args);
    if (sig == _lastSig) return; // nothing changed → don't churn the activity
    _lastSig = sig;
    LiveActivity.update(args);
  }

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

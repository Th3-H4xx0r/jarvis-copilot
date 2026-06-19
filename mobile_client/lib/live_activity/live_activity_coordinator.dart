import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../api/coding_sessions.dart';
import '../api/island_designs.dart';
import '../coding/coding_models.dart';
import '../island/island_auto.dart';
import '../island/island_bindings.dart';
import '../island/island_models.dart';
import '../island/island_sync.dart';
import '../services/app_lifecycle.dart';
import '../services/credentials.dart';
import 'la_poll_policy.dart';

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
    _island = IslandApi(_api.api);
    // Receive the per-activity APNs push token from native and register it so
    // the server can push-to-update the activity while the app is suspended.
    LiveActivity.setPushTokenHandler(_onPushToken);
  }

  // ── custom Dynamic Island designs ──
  late final IslandApi _island;
  final IslandSync _islandSync = IslandSync();
  IslandCatalog _catalog = IslandCatalog.empty;
  DateTime _lastIslandFetch = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _islandFetchInterval = Duration(seconds: 15);

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

  /// Set by the Coding page's tab-visibility hook. When the user is looking at
  /// the Coding tab we keep the fast cadence even if no session is live yet.
  bool codingVisible = false;
  void setCodingVisible(bool v) => codingVisible = v;

  DateTime _lastFetch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUsageFetch = DateTime.fromMillisecondsSinceEpoch(0);

  void _startPoll() {
    _stopPoll();
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!_enabled) return;
      if (AppLifecycle.isForeground) {
        final now = DateTime.now();
        final want = laPollInterval(
          voiceActive: _voiceState != 'idle',
          codingVisible: codingVisible,
          sessionTotal: _sessionTotal,
        );
        if (now.difference(_lastFetch) >= want) {
          // _refreshCoding() advances _lastFetch itself (synchronously, before
          // its first await), so the next tick sees the updated time.
          unawaited(_refreshCoding());
        }
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
    // Mark the fetch time here so the manual refreshes in start()/onResume()/
    // setEnabled() also advance the cadence gate — otherwise the next periodic
    // tick would immediately double-fetch ~5s after a manual refresh.
    _lastFetch = DateTime.now();
    try {
      final view = await _api.listProjectsExpanded();
      Map<String, dynamic>? usage;
      if (shouldFetchUsage(now: DateTime.now(), lastUsageFetch: _lastUsageFetch)) {
        usage = await _api.getUsage();
        _lastUsageFetch = DateTime.now();
      }
      _applyFleet(view, usage); // usage==null → _applyFleet keeps the last snapshot
      await _maybeRefreshIsland();
      _push();
    } catch (_) {
      // transient — keep the last snapshot, retry next tick
    }
  }

  /// Fetch the Dynamic Island design catalog + selection (rarely changes, so
  /// gated) and cache changed designs into the iOS App Group. Best-effort: an
  /// older server / offline keeps the last catalog (empty → legacy voice/coding
  /// behavior).
  Future<void> _maybeRefreshIsland() async {
    final now = DateTime.now();
    if (now.difference(_lastIslandFetch) < _islandFetchInterval) return;
    _lastIslandFetch = now;
    try {
      final cat = await _island.fetchCatalog();
      _catalog = cat;
      await _islandSync.sync(cat.designs);
    } catch (_) {
      // keep the previous catalog
    }
  }

  /// Global live sources the auto-engine + binding resolver can read. Per-design
  /// jarvis.* values come from the server (catalog.data), not here.
  Sources _buildSources() => <String, dynamic>{
        'time.now': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'coding.sessions': _sessionTotal,
        if (_usage5 >= 0) 'coding.usage5': _usage5,
        if (_usageWeek >= 0) 'coding.usageWeek': _usageWeek,
      };

  static int _statePriority(String s) {
    switch (s) {
      case 'waiting':
        return 0;
      case 'working':
        return 1;
      case 'idle':
        return 2;
      default:
        return 3; // dim (forgotten detached+idle) — sorts last
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
      // Per-session sub-states ordered waiting>working>idle>dim (for the split
      // bar). fleetState marks a forgotten detached+idle session as 'dim'.
      final subs = live.map((s) => s.fleetState).toList()
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
        state: s.fleetState,
        recency: s.recencyTs,
        subs: [s.fleetState],
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
    if (live.any((s) => s.fleetState == 'waiting')) return 'waiting';
    if (live.any((s) => s.fleetState == 'working')) return 'working';
    if (live.any((s) => s.fleetState == 'idle')) return 'idle';
    return 'dim'; // every live session here is a forgotten detached+idle one
  }

  static const Map<String, String> _shortState = {
    'working': 'w',
    'waiting': 'p',
    'idle': 'i',
    'dim': 'd',
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
    final codingLive = _sessionTotal > 0;

    String mode;
    var coding = false;
    var designId = '';
    var designVersion = 0;
    var dataJson = '';

    if (_catalog.entries.isEmpty) {
      // Island catalog not loaded yet (or older server) → legacy behavior:
      // voice wins, else coding when sessions live, else voice-idle launcher.
      mode = voiceActive ? 'voice' : (codingLive ? 'coding' : 'voice');
      coding = mode == 'coding';
    } else {
      final sources = _buildSources();
      final active = selectActiveDesign(
        catalog: _catalog,
        voiceActive: voiceActive,
        codingLive: codingLive,
        sources: sources,
        now: DateTime.now(),
      );
      if (active.isCustom && active.id != null) {
        final d = _catalog.designById(active.id!);
        if (d != null) {
          mode = 'custom';
          designId = d.id;
          designVersion = d.version;
          dataJson = jsonEncode(
              resolveData(d, sources, _catalog.dataFor(d.id)));
        } else {
          mode = codingLive ? 'coding' : 'voice';
          coding = mode == 'coding';
        }
      } else if (active.kind == 'coding') {
        mode = 'coding';
        coding = true;
      } else {
        // 'voice' (active turn or pinned) or 'none' (resting launcher)
        mode = 'voice';
      }
    }

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
      'designId': designId,
      'designVersion': designVersion,
      'data': dataJson,
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

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException, MethodChannel;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/devices.dart';
import '../api/sessions.dart';
import '../api/voice.dart';
import '../live_activity/live_activity_coordinator.dart';
import '../main.dart' as app; // for ws.connected (Live Activity footer)
import '../services/api_client.dart';
import 'audio_queue.dart';
import 'device_icon.dart';
import 'voice_state.dart';

/// Drives the native voice screen. Owns the mic, the FSM, the audio
/// playback queue, and both conversation transports:
///
///  • Quality  — push-to-talk: record a clip, POST /api/voice/quality-turn,
///                stream back transcript + text + MP3 segments.
///  • Realtime — continuous: stream 16 kHz PCM over /api/voice/s2s/ws with
///                client-side VAD + barge-in, play 24 kHz PCM replies.
///
/// The UI listens via [ChangeNotifier].
class VoiceController extends ChangeNotifier {
  VoiceController(ApiClient api)
      : _voice = VoiceApi(api),
        _sessions = SessionsApi(api) {
    _audio = AudioQueue(
      onIdle: _onPlaybackIdle,
      onPlaybackStart: _onPlaybackStart,
      onAmplitude: (a) => amplitude.value = a,
      onClipStart: _onClipStart,
      onPosition: _onClipPosition,
    );
    // Keep the Live Activity's Connected/Offline footer live.
    try {
      app.ws.connected.addListener(_onConnChanged);
    } catch (_) {}
  }

  final VoiceApi _voice;
  final SessionsApi _sessions;
  late final AudioQueue _audio;
  final _recorder = AudioRecorder();

  // ── Public reactive state ─────────────────────────────────────
  VoiceState state = VoiceState.idle;
  // Realtime-only for now (push-to-talk hidden in the UI). The quality-mode
  // code paths remain in the controller but are no longer user-selectable.
  VoiceMode mode = VoiceMode.realtime;
  final ValueNotifier<double> amplitude = ValueNotifier(0);
  String userTranscript = '';
  String assistantText = ''; // plain (markdown-stripped) reply, joined segments
  String? toolStatus; // e.g. "Running search_web"
  String? error;
  bool muted = false;

  // ── Karaoke highlight ─────────────────────────────────────────
  // Number of leading whitespace-delimited words of [assistantText] that have
  // been spoken so far. The voice screen colours these white and the rest
  // grey, advancing word-by-word as each TTS clip plays. See [_Seg].
  int spokenWords = 0;
  final List<_Seg> _segs = []; // reply segments, in arrival order
  int _totalWords = 0; // running word count across all segments
  int _curSeg = -1; // index of the segment whose clip is currently playing

  bool get active => state != VoiceState.idle && state != VoiceState.error;

  static const int _micRate = 16000;

  // ── Internal ──────────────────────────────────────────────────
  StreamSubscription<Uint8List>? _micSub;
  final List<int> _pcm = []; // quality-mode capture buffer
  StreamSubscription? _qualitySub;
  String? _sessionId;

  // Realtime WS + VAD + inbound audio assembly.
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  bool _spoke = false;
  int _silenceMs = 0;
  int _lastFrameMs = 0;
  // After playback drains we wait this long for a trailing segment before
  // resuming listening — replies arrive as several segments with gaps, so
  // resuming instantly made the orb flip listening↔speaking mid-reply.
  Timer? _resumeTimer;
  static const int _resumeGraceMs = 1600;
  // While "thinking", reassure the user if the server is taking a while and
  // hasn't streamed anything yet (a long tool turn, or a stalled transport).
  // Without this a slow turn looks like a frozen/dead app — the original
  // "thinking then nothing" complaint.
  Timer? _thinkingWatchdog;
  static const int _thinkingWatchdogMs = 18000;
  String _inFormat = 'pcm_s16le';
  int _inRate = 24000;
  final List<int> _segPcm = [];
  final List<int> _segMp3 = [];

  // VAD thresholds (normalized 0..1), mirroring voice.js.
  static const double _speechThreshold = 0.08;
  static const double _silenceThreshold = 0.04;
  static const double _bargeInThreshold = 0.40;
  static const int _endSilenceMs = 1500;

  void _set(VoiceState s) {
    state = s;
    _pushLiveActivity();
    notifyListeners();
  }

  // ── Live Activity (Dynamic Island) ────────────────────────────
  // Latest DESIRED content + last SENT content. We dedupe (skip no-change) and
  // trailing-throttle so we don't flood iOS's Live Activity update budget —
  // flooding made the island flicker and get stuck on a stale state (e.g.
  // showing "Listening" after Stop because the final "idle" update was dropped).
  String _laState = '', _laTranscript = '', _laActivity = '', _laDevices = '';
  bool _laConnected = true, _laSent = false;
  DateTime _lastLAPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _laTimer;

  // Online connected devices shown in the Live Activity strip (icon kinds, e.g.
  // ["laptop","phone"]). Pulled from the server's /api/devices, refreshed lazily
  // (≤ every 15s while the activity is live) so it isn't fetched on every push.
  List<String> _deviceKinds = const [];
  DateTime _devicesAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _devicesFetching = false;

  void _onConnChanged() => _pushLiveActivity();

  /// Recompute the desired Live Activity content and flush it (deduped +
  /// throttled). Called on every state change and on connection changes.
  void _pushLiveActivity() {
    final s = state == VoiceState.connecting ? 'thinking' : state.name;
    // Bound the transcript — a long monologue could blow the Live Activity's
    // ~4 KB ContentState budget and make iOS silently reject the update.
    final transcript = _firstLine(userTranscript);
    final activity = _outputLine();
    final connected = _liveConnected();
    _maybeRefreshDevices(); // keeps _deviceKinds current; re-pushes if it changes
    final devices = _deviceKinds;
    final devicesKey = devices.join(',');
    // Nothing new on screen → don't churn the activity.
    if (_laSent &&
        s == _laState &&
        transcript == _laTranscript &&
        activity == _laActivity &&
        connected == _laConnected &&
        devicesKey == _laDevices) {
      _laTimer?.cancel();
      _laTimer = null;
      return;
    }
    void send() {
      _laTimer = null;
      _laState = s;
      _laTranscript = transcript;
      _laActivity = activity;
      _laConnected = connected;
      _laDevices = devicesKey;
      _laSent = true;
      _lastLAPush = DateTime.now();
      // Report to the single Live Activity owner; it merges voice + coding and
      // pushes the native channel (was a direct LiveActivity.update — having two
      // independent pushers over one activity was the dueling-pusher bug class).
      LiveActivityCoordinator.instance?.reportVoice(
        state: s,
        transcript: transcript,
        activity: activity,
        connected: connected,
        devices: devices,
      );
    }

    // Terminal/resting states bypass the throttle so the Live Activity never
    // sticks on a stale state (e.g. showing "Listening" after Stop).
    final terminal = state == VoiceState.idle || state == VoiceState.error;
    final sinceMs = DateTime.now().difference(_lastLAPush).inMilliseconds;
    if (terminal || sinceMs >= 450) {
      _laTimer?.cancel();
      send();
    } else {
      // Trailing edge: re-run after the window so the LATEST state is sent.
      _laTimer ??= Timer(Duration(milliseconds: 450 - sinceMs), _pushLiveActivity);
    }
  }

  /// Refresh the online-device list (for the Live Activity strip) at most once
  /// every 15s. Fire-and-forget: on success it updates [_deviceKinds] and
  /// re-pushes so the new icons land. Failures keep the last-known list.
  void _maybeRefreshDevices() {
    if (_devicesFetching) return;
    if (DateTime.now().difference(_devicesAt).inSeconds < 15) return;
    _devicesFetching = true;
    () async {
      try {
        final list = await DevicesApi(app.api).list();
        final kinds = <String>[
          for (final d in list)
            if (d['online'] == true) deviceIconKind(d),
        ];
        _deviceKinds = kinds.take(6).toList(growable: false); // strip + 4KB cap
        _devicesAt = DateTime.now();
        _pushLiveActivity();
      } catch (_) {
        _devicesAt = DateTime.now(); // back off on error too
      } finally {
        _devicesFetching = false;
      }
    }();
  }

  /// JARVIS's side of the line — a reply snippet or tool status (the user's
  /// spoken text is sent separately as `transcript`). Empty when there's
  /// nothing to show (the state label covers "Listening"/"Thinking").
  String _outputLine() {
    if (error != null) return error!;
    if (toolStatus != null && toolStatus!.isNotEmpty) return toolStatus!;
    if (state == VoiceState.speaking && assistantText.isNotEmpty) {
      return _firstLine(assistantText);
    }
    return '';
  }

  String _firstLine(String s) {
    final t = s.trim();
    final nl = t.indexOf('\n');
    final line = nl >= 0 ? t.substring(0, nl) : t;
    return line.length > 120 ? '${line.substring(0, 120)}…' : line;
  }

  bool _liveConnected() {
    try {
      return app.ws.connected.value;
    } catch (_) {
      return true;
    }
  }

  void setMode(VoiceMode m) {
    if (m == mode) return;
    stopAll();
    mode = m;
    notifyListeners();
  }

  void toggleMute() {
    muted = !muted;
    notifyListeners();
  }

  // ── Permission ────────────────────────────────────────────────
  /// Returns true if mic permission is granted. The page shows the
  /// settings dialog when this returns false.
  Future<bool> ensureMic() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<String> _ensureSession() async {
    if (_sessionId != null) return _sessionId!;
    // Use the server's dedicated, persistent "Voice" chat — NOT whatever
    // session is most-recent. The old code grabbed index 0 of /api/sessions,
    // which is sorted recent-first and includes coding/CLI/Telegram channels;
    // voice then ran against a session wired to a provider+model it couldn't
    // use (e.g. Codex with an empty model) and silently failed. The server
    // get-or-creates this session with a valid model/provider.
    try {
      final id = await _voice.voiceSessionId();
      if (id.isNotEmpty) return _sessionId = id;
    } catch (_) {}
    // Fallback for older servers without /api/voice/session: make a plain
    // chat titled "Voice".
    final created = await _sessions.create(title: 'Voice');
    final session = (created['session'] as Map?) ?? created;
    final id = (session['session_id'] ?? '').toString();
    if (id.isEmpty) throw StateError('Could not create a voice session');
    return _sessionId = id;
  }

  // ── Primary action (the big button) ───────────────────────────
  /// Quality mode: toggles recording (tap to talk, tap to send).
  /// Realtime mode: toggles the streaming session on/off.
  Future<void> primaryAction() async {
    if (mode == VoiceMode.quality) {
      if (state == VoiceState.listening) {
        await _stopQualityAndSend();
      } else if (state == VoiceState.idle || state == VoiceState.error) {
        await _startQuality();
      }
    } else {
      if (active) {
        await stopAll();
      } else {
        await _startRealtime();
      }
    }
  }

  // ════════════════════════════════════════════════════════════
  // QUALITY MODE (push-to-talk → /api/voice/quality-turn)
  // ════════════════════════════════════════════════════════════
  Future<void> _startQuality() async {
    error = null;
    userTranscript = '';
    _resetSpeech();
    toolStatus = null;
    await _audio.stop();
    _pcm.clear();
    try {
      final stream = await _startMicStream();
      _micSub = stream.listen((chunk) {
        _pcm.addAll(chunk);
        amplitude.value = _peak(chunk);
      });
      _set(VoiceState.listening);
    } catch (e) {
      _fail('Could not start recording: $e');
    }
  }

  Future<void> _stopQualityAndSend() async {
    _set(VoiceState.thinking);
    amplitude.value = 0;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}

    final audio = Uint8List.fromList(_pcm);
    _pcm.clear();
    if (audio.length < 1000) {
      _fail("Didn't catch that — try again.");
      return;
    }
    try {
      final sid = await _ensureSession();
      _qualitySub = _voice
          .qualityTurn(
            audioBase64: base64.encode(audio),
            sessionId: sid,
            sampleRate: _micRate,
          )
          .listen(_onQualityEvent, onError: (e) => _fail('$e'), onDone: () {
        // The stream is done; if nothing is playing, settle to idle.
        if (!_audio.isBusy && state != VoiceState.error) _set(VoiceState.idle);
      });
    } catch (e) {
      _fail('$e');
    }
  }

  void _onQualityEvent(Map<String, dynamic> ev) {
    final type = (ev['type'] ?? '').toString();
    switch (type) {
      case 'transcript':
        userTranscript = (ev['text'] ?? '').toString();
        _pushLiveActivity();
        notifyListeners();
        break;
      case 'segment':
        final kind = (ev['kind'] ?? '').toString();
        if (kind == 'tool') {
          final name = (ev['name'] ?? 'tool').toString();
          final status = (ev['status'] ?? 'started').toString();
          toolStatus = status == 'completed' ? null : 'Running $name';
          if (state != VoiceState.speaking) _set(VoiceState.thinking);
        } else if (kind == 'text') {
          final text = (ev['text'] ?? '').toString();
          if (text.isNotEmpty) _appendSpeech(text);
          final audioB64 = (ev['audio_base64'] ?? '').toString();
          if (audioB64.isNotEmpty) {
            // Pair this clip with the segment just appended (quality mode
            // hands text + audio together, so it's the last one).
            final tag = _segs.isEmpty ? null : _segs.length - 1;
            if (tag != null) _segs[tag].audioAssigned = true;
            _audio.enqueueMp3(base64.decode(audioB64), tag: tag);
            _set(VoiceState.speaking);
          }
          notifyListeners();
        }
        break;
      case 'error':
        _fail((ev['error'] ?? 'Voice request failed').toString());
        break;
      case 'done':
        toolStatus = null;
        if (!_audio.isBusy && state != VoiceState.error) {
          _finalizeSpoken();
          _set(VoiceState.idle);
        }
        break;
    }
  }

  // ════════════════════════════════════════════════════════════
  // REALTIME MODE (/api/voice/s2s/ws)
  // ════════════════════════════════════════════════════════════
  Future<void> _startRealtime() async {
    error = null;
    userTranscript = '';
    _resetSpeech();
    toolStatus = null;
    _spoke = false;
    _silenceMs = 0;
    _capturePaused = false;
    _micRestartPending = false;
    await _setAudioProfile('voice'); // mic-capable, loud speaker route
    _set(VoiceState.connecting);
    try {
      final sid = await _ensureSession();
      // Clear any stream the server still thinks is running for this
      // session (e.g. the app was backgrounded mid-turn) — otherwise the
      // next turn fails with "session already has an active stream".
      await _cancelActiveStream(sid);
      final channel = await _voice.openRealtime();
      _ws = channel;
      _wsSub = channel.stream.listen(
        _onWsMessage,
        onError: (e) => _fail('Voice connection error: $e'),
        onDone: () {
          _cancelThinkingWatchdog(); // socket closed → stop reassuring
          if (active) _set(VoiceState.idle);
        },
      );
      _sendJson({'type': 'begin_turn', 'sample_rate': _micRate, 'session_id': sid});

      final stream = await _startMicStream();
      _micSub = stream.listen(_onRealtimeFrame);
      _set(VoiceState.listening);
    } catch (e) {
      _fail('Could not start voice: $e');
    }
  }

  void _onRealtimeFrame(Uint8List chunk) {
    final amp = _peak(chunk);
    // Drive the orb only while listening (playback drives it otherwise).
    if (state == VoiceState.listening) amplitude.value = amp;

    if (muted) return;

    // Barge-in: a loud frame during playback interrupts the assistant.
    if (state == VoiceState.speaking) {
      if (amp > _bargeInThreshold) {
        _sendJson({'type': 'interrupt'});
        unawaited(_audio.stop());
        _resetVad();
        _set(VoiceState.listening);
      }
      return; // don't stream our own playback back to STT
    }

    if (state != VoiceState.listening) return;
    _sendBinary(chunk);

    // Client-side VAD: wait for speech, then end on sustained silence.
    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = _lastFrameMs == 0 ? 0 : (now - _lastFrameMs);
    _lastFrameMs = now;
    if (!_spoke) {
      if (amp > _speechThreshold) _spoke = true;
    } else {
      if (amp < _silenceThreshold) {
        _silenceMs += dt;
        if (_silenceMs >= _endSilenceMs) {
          _endRealtimeTurn();
        }
      } else {
        _silenceMs = 0;
      }
    }
  }

  void _endRealtimeTurn() {
    if (state != VoiceState.listening) return;
    _resumeTimer?.cancel();
    _sendJson({'type': 'end_turn'});
    _resetVad();
    amplitude.value = 0;
    error = null; // clear any failure message from the previous turn
    // A new user turn begins → clear the previous reply + its highlight so the
    // incoming reply starts fresh (within one realtime session segments would
    // otherwise accumulate across turns). See [_resetSpeech].
    _resetSpeech();
    _set(VoiceState.thinking);
    _armThinkingWatchdog(); // reassure if the server is slow / nothing arrives
  }

  /// User explicitly signals end-of-speech (the "Done" button).
  void finishSpeaking() {
    if (mode == VoiceMode.realtime && state == VoiceState.listening) {
      _endRealtimeTurn();
    }
  }

  /// User interrupts the assistant (the "Interrupt" button).
  void interrupt() {
    if (mode == VoiceMode.realtime &&
        (state == VoiceState.speaking || state == VoiceState.thinking)) {
      _resumeTimer?.cancel();
      _cancelThinkingWatchdog();
      _sendJson({'type': 'interrupt'});
      unawaited(_audio.stop());
      _resetVad();
      _set(VoiceState.listening);
    }
  }

  void _resetVad() {
    _spoke = false;
    _silenceMs = 0;
    _lastFrameMs = 0;
  }

  void _onWsMessage(dynamic data) {
    if (data is String) {
      Map<String, dynamic> msg;
      try {
        msg = Map<String, dynamic>.from(json.decode(data) as Map);
      } catch (_) {
        return;
      }
      final type = (msg['type'] ?? '').toString();
      if (type != 'transcript' && type != 'assistant_text') {
        debugPrint('[voice] ws msg: $type ${msg.length > 1 ? msg.keys : ''}');
      }
      switch (type) {
        case 'ready':
          break;
        case 'transcript':
          userTranscript = (msg['text'] ?? '').toString();
          _pushLiveActivity(); // show your line on the island while listening
          notifyListeners();
          break;
        case 'assistant_text':
          // Reply is still in progress — cancel any pending resume and
          // show "thinking" until audio actually starts (playback flips
          // us to "speaking"). This keeps the orb from saying "listening"
          // while the reply is mid-flight.
          _resumeTimer?.cancel();
          _cancelThinkingWatchdog(); // real reply text is now arriving
          _appendSpeech((msg['text'] ?? '').toString());
          toolStatus = null;
          if (state != VoiceState.speaking) _set(VoiceState.thinking);
          break;
        case 'tool':
          _resumeTimer?.cancel();
          final name = (msg['name'] ?? 'tool').toString();
          final status = (msg['status'] ?? 'started').toString();
          toolStatus = status == 'completed' ? null : 'Running $name';
          if (state != VoiceState.speaking) _set(VoiceState.thinking);
          break;
        case 'audio_meta':
          _resumeTimer?.cancel();
          _inFormat = (msg['format'] ?? 'pcm_s16le').toString();
          _inRate = _asInt(msg['sample_rate']) ?? 24000;
          _segPcm.clear();
          _segMp3.clear();
          break;
        case 'audio_end':
          _flushSegment();
          break;
        case 'end_turn':
          _onRealtimeTurnEnd((msg['reason'] ?? '').toString());
          break;
      }
    } else if (data is List<int>) {
      // Binary audio frame for the current segment.
      if (_inFormat == 'mp3') {
        _segMp3.addAll(data);
      } else {
        _segPcm.addAll(data);
      }
    } else {
      debugPrint('[voice] ws unexpected frame type: ${data.runtimeType}');
    }
  }

  void _flushSegment() {
    debugPrint(
        '[voice] flushSegment format=$_inFormat pcm=${_segPcm.length} mp3=${_segMp3.length}');
    // Pair this clip with the most recent text segment that doesn't yet have
    // audio, so the karaoke highlight can time its words against the clip.
    int? tag;
    for (var i = _segs.length - 1; i >= 0; i--) {
      if (!_segs[i].audioAssigned) {
        _segs[i].audioAssigned = true;
        tag = i;
        break;
      }
    }
    if (_inFormat == 'mp3') {
      if (_segMp3.isNotEmpty) {
        _audio.enqueueMp3(Uint8List.fromList(_segMp3), tag: tag);
        _segMp3.clear();
      }
    } else {
      if (_segPcm.isNotEmpty) {
        _audio.enqueuePcm(Uint8List.fromList(_segPcm),
            sampleRate: _inRate, tag: tag);
        _segPcm.clear();
      }
    }
  }

  void _onRealtimeTurnEnd(String reason) {
    // Flush any audio that didn't get an explicit audio_end.
    _flushSegment();
    _cancelThinkingWatchdog();
    toolStatus = null;
    if (!active) return;
    // Surface real failures instead of silently resuming. The server reports
    // EVERY failure as end_turn{reason} (never a {type:"error"} frame), and we
    // used to ignore `reason` — so a failed turn looked identical to a normal
    // one ("thinking → listening, nothing spoken"). If the turn produced no
    // audio and no reply text and the reason is a failure, show a message so
    // the user knows to retry. (no_speech/empty/interrupt are benign — the
    // user simply didn't say anything / barged in — so we stay silent there.)
    const failures = {'error', 'no_reply'};
    if (failures.contains(reason) &&
        !_audio.isBusy &&
        assistantText.trim().isEmpty) {
      error = reason == 'no_reply'
          ? "I didn't catch a reply — please try again."
          : 'Something went wrong — please try again.';
      // Drop the cached session id so the NEXT connect re-resolves the voice
      // session — guards against a wedged turn repeating forever if the cached
      // id ever goes bad server-side.
      _sessionId = null;
      // Stay in the conversation (don't tear down the WS the way _fail does);
      // show the message and resume listening so the user can just retry.
      notifyListeners();
      _pushLiveActivity();
      _scheduleResumeListening();
      return;
    }
    // If audio is playing/queued, _onPlaybackIdle handles the resume once
    // it drains; otherwise (text-only / empty turn) schedule it now.
    if (!_audio.isBusy) _scheduleResumeListening();
  }

  /// A clip began playing — the assistant is talking.
  void _onPlaybackStart() {
    _resumeTimer?.cancel();
    _cancelThinkingWatchdog();
    if (state != VoiceState.speaking) _set(VoiceState.speaking);
  }

  void _onPlaybackIdle() {
    // Playback queue drained.
    if (mode == VoiceMode.realtime && active) {
      // Don't resume listening immediately — a follow-up segment often
      // arrives within a beat. Show "thinking" and wait out the grace
      // window; a new clip (onPlaybackStart) cancels the resume.
      if (state == VoiceState.speaking) _set(VoiceState.thinking);
      _scheduleResumeListening();
    } else if (mode == VoiceMode.quality && state == VoiceState.speaking) {
      _finalizeSpoken();
      _set(VoiceState.idle);
    }
  }

  void _armThinkingWatchdog() {
    _thinkingWatchdog?.cancel();
    _thinkingWatchdog =
        Timer(const Duration(milliseconds: _thinkingWatchdogMs), () {
      if (!active || state != VoiceState.thinking) return;
      // Only fill a soft status if nothing else is showing — don't stomp a
      // real "Running <tool>" status.
      if (toolStatus == null || toolStatus!.isEmpty) {
        toolStatus = 'Still working…';
        notifyListeners();
        _pushLiveActivity(); // reflect on the Dynamic Island too
      }
      _armThinkingWatchdog(); // keep reassuring until the reply arrives
    });
  }

  void _cancelThinkingWatchdog() {
    _thinkingWatchdog?.cancel();
    _thinkingWatchdog = null;
  }

  void _scheduleResumeListening() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(milliseconds: _resumeGraceMs), () async {
      if (mode != VoiceMode.realtime || !active) return;
      if (_audio.isBusy) return; // a trailing segment is playing
      // Still backgrounded: don't resume listening / start the mic in the
      // background. resumeFromBackground handles it when we return.
      if (_capturePaused) return;
      // If the mic was released for background playback, bring it back now that
      // the reply has finished — restarting it HERE (after playback) means it
      // never interrupts a live reply.
      if (_micRestartPending || _micSub == null) {
        _micRestartPending = false;
        await _setAudioProfile('voice');
        await _audio.useBackgroundPlayback(false);
        try {
          final stream = await _startMicStream();
          _micSub = stream.listen(_onRealtimeFrame);
        } catch (e) {
          _fail('Could not resume microphone: $e');
          return;
        }
      }
      _finalizeSpoken(); // reply's done — light up any unspoken tail
      _resetVad();
      amplitude.value = 0;
      _set(VoiceState.listening);
    });
  }

  // ── Karaoke highlight ─────────────────────────────────────────
  /// Clear all reply + highlight state at the start of a new turn.
  void _resetSpeech() {
    assistantText = '';
    spokenWords = 0;
    _segs.clear();
    _totalWords = 0;
    _curSeg = -1;
  }

  /// Append a chunk of assistant reply text as a new segment. The raw text is
  /// markdown-stripped (so it matches the spoken audio) and split into words;
  /// [assistantText] is rebuilt as the joined plain reply.
  void _appendSpeech(String raw) {
    final t = _plainSpeech(raw).trim();
    if (t.isEmpty) return;
    final seg = _Seg(t, _totalWords);
    _totalWords += seg.words.length;
    _segs.add(seg);
    assistantText = _segs.map((s) => s.text).join('\n\n');
    notifyListeners();
  }

  /// A segment's TTS clip began — schedule its words across the clip duration
  /// and mark everything before it fully spoken.
  void _onClipStart(int? tag, Duration dur) {
    if (tag == null || tag < 0 || tag >= _segs.length) return;
    for (var i = 0; i < tag; i++) {
      _segs[i].localSpoken = _segs[i].words.length;
    }
    _curSeg = tag;
    final seg = _segs[tag];
    var ms = dur.inMilliseconds;
    if (ms <= 0) ms = seg.words.length * 300; // MP3 dur unknown → ~200 wpm est
    seg.schedule(ms);
    seg.localSpoken = 0;
    _recomputeSpoken();
  }

  /// Advance the highlight to match the current clip's playback position.
  void _onClipPosition(int? tag, Duration pos) {
    if (tag == null || tag != _curSeg || tag < 0 || tag >= _segs.length) return;
    final seg = _segs[tag];
    // Drop a stale position event left over from the previous (outgoing) clip:
    // it would read near that clip's end and, since advance() is monotonic,
    // would jump this segment straight to its last word.
    if (pos.inMilliseconds > seg.durMs + 300) return;
    seg.advance(pos.inMilliseconds);
    _recomputeSpoken();
  }

  void _recomputeSpoken() {
    var n = 0;
    for (var i = 0; i < _segs.length; i++) {
      if (i < _curSeg) {
        n += _segs[i].words.length;
      } else if (i == _curSeg) {
        n += _segs[i].localSpoken;
        break;
      } else {
        break;
      }
    }
    if (n != spokenWords) {
      spokenWords = n;
      notifyListeners();
    }
  }

  /// Reply finished — light up any words the position stream didn't reach.
  void _finalizeSpoken() {
    if (spokenWords != _totalWords) {
      spokenWords = _totalWords;
      notifyListeners();
    }
  }

  // ── Shared helpers ────────────────────────────────────────────
  /// Start the mic stream, retrying the iOS audio-session activation a few
  /// times. When the wake-word recognizer (or a just-ended turn) hasn't
  /// fully released the AVAudioSession yet, the first `setActive` throws
  /// "Session activation failed"; a short wait + retry clears it.
  Future<Stream<Uint8List>> _startMicStream() async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _recorder.startStream(_micConfig());
      } on PlatformException catch (e) {
        final msg = '${e.message} ${e.details}';
        final transient = msg.contains('Session activation') ||
            msg.contains('setActive') ||
            msg.contains('activation failed');
        if (transient && attempt < 4) {
          try {
            await _recorder.stop();
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 350));
          continue;
        }
        rethrow;
      }
    }
  }

  RecordConfig _micConfig() => const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _micRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 2048,
      );

  void _sendJson(Map<String, dynamic> obj) {
    try {
      _ws?.sink.add(json.encode(obj));
    } catch (_) {}
  }

  void _sendBinary(Uint8List bytes) {
    try {
      _ws?.sink.add(bytes);
    } catch (_) {}
  }

  /// Cancel any stream the server still has running for [sid]. Called
  /// before starting a turn so a previously-orphaned turn (app was
  /// backgrounded mid-reply) doesn't block us with "session already has
  /// an active stream".
  Future<void> _cancelActiveStream(String sid) async {
    try {
      final resp = await _voice.api.get(
        '/api/session',
        query: {'session_id': sid, 'messages': '0'},
      );
      final body = resp.data as Map?;
      final session = (body?['session'] as Map?) ?? body;
      final streamId = (session?['active_stream_id'] ?? '').toString();
      if (streamId.isEmpty) return;
      await _voice.api.get('/api/chat/cancel', query: {'stream_id': streamId});
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {
      // Best effort — if this fails we still try the turn.
    }
  }

  /// Peak amplitude of a PCM16-LE chunk, normalized 0..1. We use peak
  /// (not RMS) because the VAD thresholds below are calibrated against
  /// peak, matching the webui — RMS runs several times smaller, so with
  /// RMS the speech threshold was never crossed and the turn never ended.
  double _peak(Uint8List chunk) {
    if (chunk.lengthInBytes < 2) return 0;
    final data =
        chunk.buffer.asByteData(chunk.offsetInBytes, chunk.lengthInBytes);
    var peak = 0.0;
    for (var i = 0; i + 1 < data.lengthInBytes; i += 2) {
      final s = (data.getInt16(i, Endian.little) / 32768.0).abs();
      if (s > peak) peak = s;
    }
    return peak.clamp(0.0, 1.0).toDouble();
  }

  void _fail(String message) {
    error = message;
    toolStatus = null;
    _resumeTimer?.cancel();
    _cancelThinkingWatchdog();
    _teardownMic();
    unawaited(_closeWs());
    unawaited(_audio.stop());
    amplitude.value = 0;
    _set(VoiceState.error);
  }

  Future<void> _teardownMic() async {
    await _micSub?.cancel();
    _micSub = null;
    await _qualitySub?.cancel();
    _qualitySub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  Future<void> _closeWs() async {
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
  }

  // ── Backgrounding ─────────────────────────────────────────────
  bool _capturePaused = false;
  // When we return to the foreground while a reply is still playing we do NOT
  // restart the mic immediately — restarting it reconfigures the audio session
  // and interrupts the live playback (the "freezes on return" bug). Instead we
  // flag it and restart the mic once playback drains.
  bool _micRestartPending = false;

  static const MethodChannel _audioSessionCh =
      MethodChannel('jarviscopilot/audio_session');

  /// Switch the native iOS AVAudioSession profile: 'voice' (mic-capable, loud
  /// speaker route) or 'playback' (full-volume, background-capable media — keeps
  /// a backgrounded reply LOUD, like a phone call). No-op off iOS. This is the
  /// authoritative re-route; audioplayers' setCategory alone doesn't move a live
  /// session, which is why the background volume dropped.
  Future<void> _setAudioProfile(String profile) async {
    if (!Platform.isIOS) return;
    try {
      await _audioSessionCh.invokeMethod(profile);
    } catch (_) {}
  }

  /// App went to the background. Keep the WebSocket and audio playback
  /// alive so the current reply finishes speaking, but stop capturing
  /// the mic so we're not recording while backgrounded. (record's stop()
  /// tears down its engine without deactivating the shared audio session,
  /// so playback keeps going.)
  Future<void> pauseForBackground() async {
    if (mode != VoiceMode.realtime || !active) return;
    _capturePaused = true;
    _cancelThinkingWatchdog(); // don't fire reassurance timers while backgrounded
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    // Mic released → force the iOS session to full-volume .playback (natively,
    // with setActive + speaker override) so the in-flight reply keeps playing
    // LOUD in the background instead of dropping to the quiet voice route.
    await _setAudioProfile('playback');
    await _audio.useBackgroundPlayback(true); // keep audioplayers' context in sync
  }

  /// App returned to the foreground — resume mic capture if we paused it.
  Future<void> resumeFromBackground() async {
    if (!_capturePaused) return;
    _capturePaused = false;
    if (mode != VoiceMode.realtime || !active) return;
    // If a reply is still playing, DO NOT restart the mic now — restarting it
    // reconfigures the audio session and interrupts the live playback (the
    // "freezes on return" bug). Defer it; _scheduleResumeListening restarts the
    // mic once playback drains. Keep the loud playback session meanwhile.
    if (_audio.isBusy || state == VoiceState.speaking) {
      _micRestartPending = true;
      return;
    }
    // Nothing playing — safe to switch back to the mic-capable session and
    // restart capture now.
    await _setAudioProfile('voice');
    await _audio.useBackgroundPlayback(false);
    try {
      final stream = await _startMicStream();
      _micSub = stream.listen(_onRealtimeFrame);
      _resetVad();
      _set(VoiceState.listening);
    } catch (e) {
      _fail('Could not resume microphone: $e');
    }
  }

  /// Stop everything and return to idle (the Stop button / mode switch).
  Future<void> stopAll() async {
    _resumeTimer?.cancel();
    _cancelThinkingWatchdog();
    _micRestartPending = false;
    await _teardownMic();
    await _closeWs();
    await _audio.stop();
    _resetVad();
    // Keep the reply on screen after Stop — DON'T erase it and DON'T finalize.
    // Freezing it exactly where it stopped (partial highlight, same scroll
    // position) is honest about how far it got and doesn't jump the view. It's
    // cleared when the next turn starts (_startRealtime/_startQuality →
    // _resetSpeech).
    amplitude.value = 0;
    if (state != VoiceState.error) _set(VoiceState.idle);
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _thinkingWatchdog?.cancel();
    _laTimer?.cancel();
    try {
      app.ws.connected.removeListener(_onConnChanged);
    } catch (_) {}
    _teardownMic();
    _closeWs();
    _audio.dispose();
    _recorder.dispose();
    amplitude.dispose();
    super.dispose();
  }
}

int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.round();
  return int.tryParse(v.toString());
}

/// One spoken segment of the reply — a sentence-ish chunk that has its own TTS
/// clip. Owns its word tokens and a duration-proportional schedule used to
/// advance the karaoke highlight as the clip plays. Because the schedule is
/// rebuilt from each clip's measured duration, the highlight re-syncs to real
/// audio at every segment boundary (drift can't accumulate).
class _Seg {
  _Seg(this.text, this.wordOffset) : words = _wordTokens(text);

  final String text; // plain (markdown-stripped) display text
  final int wordOffset; // global index of this segment's first word
  final List<String> words; // whitespace-delimited tokens
  bool audioAssigned = false; // a clip has been paired to this segment
  int durMs = 0; // this segment's clip duration (set by schedule)
  List<double> _starts = const []; // per-word start time (ms) within the clip
  int localSpoken = 0; // words spoken so far within this segment

  /// Spread [words] across a clip of [clipMs]. Each word's weight = its length
  /// plus extra for trailing punctuation (a natural pause), so longer words
  /// and clause/sentence breaks take proportionally more time.
  void schedule(int clipMs) {
    durMs = clipMs;
    final n = words.length;
    if (n == 0) {
      _starts = const [];
      return;
    }
    final weights = List<double>.filled(n, 0);
    var total = 0.0;
    for (var i = 0; i < n; i++) {
      final w = words[i];
      var wt = w.length.toDouble() + 1.0;
      final last = w.isNotEmpty ? w[w.length - 1] : '';
      if ('.!?'.contains(last)) {
        wt += 6.0; // sentence end → long pause
      } else if (',;:'.contains(last)) {
        wt += 3.0; // clause break → short pause
      }
      weights[i] = wt;
      total += wt;
    }
    _starts = List<double>.filled(n, 0);
    var cum = 0.0;
    for (var i = 0; i < n; i++) {
      _starts[i] = total > 0 ? (cum / total) * durMs : 0;
      cum += weights[i];
    }
  }

  /// Move the highlight forward to whatever word the clip is up to at [posMs].
  /// Monotonic — it never steps backward on a jittery position report.
  void advance(int posMs) {
    var k = localSpoken;
    while (k < _starts.length && _starts[k] <= posMs) {
      k++;
    }
    if (k > localSpoken) localSpoken = k;
  }
}

final RegExp _wordRe = RegExp(r'\S+');
List<String> _wordTokens(String s) =>
    _wordRe.allMatches(s).map((m) => m.group(0)!).toList();

/// Strip markdown so the reply reads like clean speech — matches what the
/// server synthesizes (see voice.py `_speakable`). Kept here (not the page) so
/// the displayed text and the word schedule tokenize identically.
String _plainSpeech(String text) {
  var s = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!);
  s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'\*\*|\*|__|_|~~|`'), '');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

// The iOS Live Activity channel now lives in
// `lib/live_activity/live_activity_coordinator.dart` (class `LiveActivity`),
// owned by `LiveActivityCoordinator`. VoiceController reports its state to that
// coordinator (see `_pushLiveActivity`) rather than pushing the channel here.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/devices.dart';
import '../api/sessions.dart';
import '../api/voice.dart';
import '../live_activity/live_activity_coordinator.dart';
import '../main.dart' as app; // for ws.connected (Live Activity footer)
import '../services/api_client.dart';
import '../services/app_lifecycle.dart';
import '../services/chat_sync_bus.dart';
import '../services/invoke_runner.dart' show localToolMissed;
import '../services/local_ai_settings.dart';
import '../services/local_executor.dart';
import '../services/model_selection.dart';
import '../services/on_device_ai.dart';
import '../services/on_device_ai_types.dart';
import 'audio_queue.dart';
import 'device_icon.dart';
import 'endpointer.dart';
import 'local_tts.dart';
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

  // audio_session is the SINGLE owner of the iOS AVAudioSession (record's own
  // management is disabled — see _micConfig). Configured once with
  // .playAndRecord + .defaultToSpeaker and kept ACTIVE for the whole
  // conversation, so the loud speaker route persists even after the mic stops
  // on background (previously the route fell back to the quiet earpiece).
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

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

  // The last on-device voice reply's transcript, kept so the user can re-run that
  // turn on the SERVER ("Try on server") if the local answer was poor. One-shot:
  // cleared on retry, on a new spoken turn, and on session end.
  String? _lastLocalTranscript;
  bool get canRetryOnServer =>
      _lastLocalTranscript != null &&
      state == VoiceState.listening &&
      !_audio.isBusy;

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
  /// Adaptive end-of-speech detection (plan 1.1) — replaces the old fixed
  /// 1500 ms amplitude timer. All of its tuning lives in [Endpointer].
  final Endpointer _endpointer = Endpointer();
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
  final List<int> _segMp3 = [];
  /// Karaoke segment the CURRENT streamed PCM reply belongs to (plan 1.7).
  int? _pcmTag;

  // On-device voice: this turn's captured mic PCM (for on-device STT), and an
  // epoch that invalidates an in-flight local attempt if the user interrupts /
  // stops / starts a new turn while we're awaiting STT/route/TTS.
  final List<int> _turnPcm = [];
  int _turnEpoch = 0;
  String? _escalateText; // on-device transcript to hand the server on escalation
  static const int _maxTurnPcmBytes = 16000 * 2 * 30; // ~30s @ 16kHz mono

  // Barge-in threshold (normalized 0..1), mirroring voice.js. The speech /
  // silence thresholds now live in [Endpointer] (plan 1.1).
  static const double _bargeInThreshold = 0.40;
  // Sustained-speech barge-in: a single frame over 0.40 almost never happens
  // for normal speech once echo cancellation has attenuated the mic, so also
  // trip on a run of moderately loud frames (~200 ms) — the reply's own echo
  // leak stays short and quiet, real speech doesn't.
  static const double _bargeInSustainAmp = 0.18;
  static const int _bargeInSustainFrames = 4;
  int _bargeRun = 0;

  bool _bargeInDetected(double amp) {
    if (amp > _bargeInThreshold) {
      _bargeRun = 0;
      return true;
    }
    _bargeRun = amp > _bargeInSustainAmp ? _bargeRun + 1 : 0;
    if (_bargeRun >= _bargeInSustainFrames) {
      _bargeRun = 0;
      return true;
    }
    return false;
  }

  // ── Latency instrumentation (plan 0.2) ────────────────────────────────────
  // One id per spoken turn so a client span can be lined up with the server's
  // `{"type":"latency"}` frames for the same turn.
  String? _turnId;
  int? _speechEndMs; // wall clock at end-of-speech, for speech_end→first_audio
  bool _firstAudioLogged = false;

  /// Set as soon as the server produces ANYTHING for this turn (text, tool, or
  /// audio). The fallback local-action race (plan 4.1) gives up once this is
  /// true — we never interrupt a reply that has already started.
  bool _serverProducedOutput = false;

  // ── On-device STT (plan 4.1 / 4.2) ────────────────────────────────────────
  /// Live recognition running DURING speech, fed the same mic frames we stream
  /// to the server. When present, the final transcript is ready ~0 ms after the
  /// endpointer fires and `end_turn` can carry `text`.
  SpeechStreamSession? _speech;

  /// How long after end-of-speech the BATCH on-device STT fallback may still
  /// claim a turn as a local device action. Past this the server's own STT +
  /// reply is already in flight and interrupting it would be worse than
  /// letting it answer (plan 4.1).
  static const int _kLocalActionRaceMs = 1500;

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
    AppLifecycle.voiceActive = false;

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
    _lastLocalTranscript = null;
    toolStatus = null;
    _endpointer.reset();
    _turnPcm.clear();
    _turnEpoch++;
    _set(VoiceState.connecting);
    try {
      // Own + activate the audio session BEFORE the mic/playback start, so the
      // loud speaker route is locked in for the whole conversation.
      await _ensureAudioSession();
      await _session?.setActive(true);
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
      _sendJson({
        'type': 'begin_turn',
        'sample_rate': _micRate,
        'session_id': sid,
        ..._voiceModelFields(),
      });

      final stream = await _startMicStream();
      _micSub = stream.listen(_onRealtimeFrame);
      unawaited(_startSpeechStream());
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

    // Barge-in: a loud frame during playback interrupts the assistant. Only
    // while foregrounded — backgrounded, the loud reply can leak past echo
    // cancellation and falsely trip the threshold.
    // Also while "thinking" mid-reply (the gap between sentences / a tool
    // call) once the server has started answering — the user shouldn't have
    // to wait for the next sentence to start before they can cut in.
    final replying = state == VoiceState.speaking ||
        (state == VoiceState.thinking && _serverProducedOutput);
    if (replying) {
      if (_foreground && _bargeInDetected(amp)) {
        _sendJson({'type': 'interrupt'});
        unawaited(_audio.stop());
        unawaited(LocalTts.stop());
        _resetVad();
        _abortSpeechStream();
        unawaited(_startSpeechStream()); // fresh recognizer for what they say now
        _lastLocalTranscript = null; // user barged out → no stale "Try on server"
        _set(VoiceState.listening);
      }
      return; // don't stream our own playback back to STT
    }

    if (state != VoiceState.listening) return;
    _bargeRun = 0;
    _sendBinary(chunk);
    // The platform recognizer ends its own session after a stretch of silence
    // (a user who opens the voice screen and pauses). Re-arm it BETWEEN
    // utterances so the next one is still transcribed on-device — never
    // mid-utterance, which would throw away what it has already heard.
    final speech = _speech;
    if (speech != null && speech.isDone && !_endpointer.speaking) {
      _speech = null;
      unawaited(_startSpeechStream());
    }
    // Feed the SAME frames to the on-device recognizer, so its transcript is
    // final the moment the user stops (plan 4.1) instead of starting then.
    _speech?.feed(chunk);
    // Buffer the turn locally for the BATCH on-device STT fallback (used only
    // when streaming STT isn't available). Capped to bound memory.
    if (_speech == null &&
        LocalAiSettings.instance.enabledForVoice &&
        _turnPcm.length < _maxTurnPcmBytes) {
      _turnPcm.addAll(chunk);
    }

    // Adaptive endpointing (plan 1.1). Frame duration comes from the audio
    // itself, not a wall clock, so scheduler jitter can't skew the silence
    // budget.
    final dtMs = Endpointer.frameMsForPcm16(chunk.lengthInBytes, _micRate);
    if (_endpointer.update(amp, dtMs) == EndpointEvent.endOfTurn) {
      _endRealtimeTurn();
    }
  }

  void _endRealtimeTurn() {
    if (state != VoiceState.listening) return;
    _lastLocalTranscript = null; // a new spoken turn supersedes the retry option
    _resumeTimer?.cancel();
    _resetVad();
    amplitude.value = 0;
    error = null; // clear any failure message from the previous turn
    // A new user turn begins → clear the previous reply + its highlight so the
    // incoming reply starts fresh (within one realtime session segments would
    // otherwise accumulate across turns). See [_resetSpeech].
    userTranscript = ''; // never route/show a stale transcript
    _resetSpeech();
    _set(VoiceState.thinking);

    // Latency bookkeeping for this turn (plan 0.2).
    _turnId = 'm-${DateTime.now().microsecondsSinceEpoch}';
    _speechEndMs = DateTime.now().millisecondsSinceEpoch;
    _firstAudioLogged = false;
    _serverProducedOutput = false;

    final pcm = Uint8List.fromList(_turnPcm);
    _turnPcm.clear();
    _escalateText = null;
    final epoch = ++_turnEpoch;

    // ── Path A: streaming on-device STT was running (plan 4.1) ─────────────
    // Its transcript is already final, so we lose nothing by asking for it
    // before touching the network: either the local lane handles the turn
    // outright, or `end_turn` carries `text` and the server skips its STT.
    final speech = _speech;
    _speech = null;
    if (speech != null) {
      unawaited(_finishStreamedTurn(speech, epoch));
      return;
    }

    // ── Path B: no streaming STT — server first, local action races ────────
    // The PCM has been streaming to the server all along, so `end_turn` goes
    // out NOW (zero added latency). The batch on-device STT then runs
    // CONCURRENTLY and may still claim the turn as a device-local action if it
    // finishes before the server has produced anything.
    _sendServerTurn();
    if (LocalAiSettings.instance.enabledForVoice && pcm.length > 2000) {
      unawaited(_raceLocalAction(pcm, epoch));
    } else {
      // Diagnostic: voice bypassed the on-device layer entirely. The common
      // cause is the per-surface Voice toggle being off (chat is independent).
      debugPrint('[voice] on-device SKIPPED → server. '
          'enabledForVoice=${LocalAiSettings.instance.enabledForVoice} '
          '(tier=${LocalAiSettings.instance.tier.name}, '
          'voiceToggle=${LocalAiSettings.instance.voiceEnabled}) pcmBytes=${pcm.length}');
    }
  }

  /// Path A: the on-device recognizer already has this turn's text. Route it
  /// locally if we can, otherwise escalate WITH the transcript.
  Future<void> _finishStreamedTurn(SpeechStreamSession speech, int epoch) async {
    final transcript = (await speech.stop()).trim();
    if (epoch != _turnEpoch || !active) return;
    _logSpan('stt_ready');
    if (transcript.isEmpty) {
      debugPrint('[voice] streaming STT produced nothing → server STT');
      _sendServerTurn();
      return;
    }
    userTranscript = transcript;
    _escalateText = transcript;
    _pushLiveActivity();
    notifyListeners();

    final handled = await _tryLocalTurn(transcript, epoch);
    if (epoch != _turnEpoch || !active) return;
    if (handled) {
      _lastLocalTranscript = _escalateText; // enable "Try on server"
      notifyListeners();
      _resetServerTurn(); // flush the server's buffered audio for this turn
    } else {
      _sendServerTurn(text: transcript);
    }
  }

  /// Path B: batch on-device STT running alongside an already-sent `end_turn`.
  /// It may ONLY claim a turn that is a device-local action, and only while the
  /// server hasn't said anything yet — otherwise the server's reply wins.
  Future<void> _raceLocalAction(Uint8List pcm, int epoch) async {
    final transcript =
        (await OnDeviceAi.instance.transcribe(pcm, sampleRate: _micRate)).trim();
    if (epoch != _turnEpoch || !active || transcript.isEmpty) return;
    if (_serverProducedOutput) return; // too late — the server is answering
    final since = DateTime.now().millisecondsSinceEpoch - (_speechEndMs ?? 0);
    if (since > _kLocalActionRaceMs) return;

    final decision = LocalExecutor.classify(transcript);
    debugLogLocalDecision(decision);
    if (decision is! LocalRun) return; // not a local action → let the server run
    userTranscript = transcript;
    _escalateText = transcript;
    notifyListeners();
    // Beat the server to it: cancel its turn, then do the action here.
    _sendJson({'type': 'interrupt'});
    unawaited(_audio.stop());
    final ok = await _runLocalAction(decision, transcript, epoch);
    if (epoch != _turnEpoch || !active) return;
    if (!ok) {
      // We already interrupted the server, so re-ask it with the transcript we
      // have rather than leaving the user with nothing.
      _sendServerTurn(text: transcript);
    }
  }

  /// Ask the server to run the agent on this turn. When [text] is provided it's
  /// our on-device transcript — the server skips its own STT and uses it.
  void _sendServerTurn({String? text}) {
    // client_ts / speech_end_ts let the server line its own spans up with the
    // moment the user actually stopped talking (plan 0.2). Extra keys are
    // ignored by older servers, so this stays backward compatible.
    _sendJson({
      'type': 'end_turn',
      if (text != null && text.isNotEmpty) 'text': text,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
      if (_speechEndMs != null) 'speech_end_ts': _speechEndMs,
      if (_turnId != null) 'turn_id': _turnId,
    });
    _armThinkingWatchdog(); // reassure if the server is slow / nothing arrives
  }

  // ── On-device STT session (plan 4.1 / 4.2) ────────────────────────────────

  /// Open a live recognizer for the next utterance. Best-effort and silent: a
  /// device without streaming STT simply runs the old path.
  ///
  /// We only let it PROMPT for the Speech permission when the user has opted
  /// into on-device AI for voice; otherwise we take the session only if
  /// permission was already granted, so enabling nothing still changes nothing.
  Future<void> _startSpeechStream() async {
    if (_speech != null) return;
    // Runtime kill-switch (review MINOR): forces every Android turn onto
    // server STT (the existing Path B race) without a client release, in
    // case a given OEM's on-device recognizer ignores the shared-mic pipe.
    // No effect on iOS.
    if (Platform.isAndroid && !LocalAiSettings.instance.androidStreamingStt) {
      return;
    }
    try {
      final session = await OnDeviceAi.instance.transcribeStream(
        sampleRate: _micRate,
        prompt: LocalAiSettings.instance.enabledForVoice,
      );
      if (session == null) return;
      if (!active || state == VoiceState.idle) {
        unawaited(session.cancel());
        return;
      }
      _speech = session;
    } catch (e) {
      debugPrint('[voice] streaming STT unavailable: $e');
    }
  }

  /// Drop any in-flight recognizer (barge-in, stop, teardown).
  void _abortSpeechStream() {
    final s = _speech;
    _speech = null;
    if (s != null) unawaited(s.cancel());
  }

  // ── Latency spans (plan 0.2) ──────────────────────────────────────────────

  /// Emit one structured client span. Shape matches the server's
  /// `{"turn_id":..,"span":..,"ms":..}` so both sides can be correlated.
  /// Never carries audio, transcripts or tokens.
  void _logSpan(String span, {int? sinceMs}) {
    final from = sinceMs ?? _speechEndMs;
    if (from == null) return;
    final ms = (DateTime.now().millisecondsSinceEpoch - from).toDouble();
    debugPrint(json.encode({
      'turn_id': _turnId ?? '',
      'span': span,
      'ms': ms,
    }));
  }

  /// First audible sample of the reply — the number the whole rehaul is judged
  /// on. Recorded once per turn, at the moment audio is handed to the player.
  void _noteFirstAudio() {
    if (_firstAudioLogged || _speechEndMs == null) return;
    _firstAudioLogged = true;
    _logSpan('speech_end_to_first_audio');
  }

  /// Reset the server's per-turn audio buffer (used after we answered a turn
  /// locally and skipped end_turn) so the next turn starts clean.
  void _resetServerTurn() {
    _sendJson({
      'type': 'begin_turn',
      'sample_rate': _micRate,
      if (_sessionId != null) 'session_id': _sessionId,
      ..._voiceModelFields(),
    });
    if (!_audio.isBusy) _scheduleResumeListening();
  }

  /// Re-run the last on-device voice turn on the SERVER ("Try on server"). Sends
  /// the on-device transcript so the server skips its STT and runs the agent; the
  /// reply streams + speaks through the normal path. One-shot; only valid while
  /// listening right after a local reply (see [canRetryOnServer]).
  void retryLastOnServer() {
    final t = _lastLocalTranscript;
    if (t == null || t.isEmpty || state != VoiceState.listening) return;
    _lastLocalTranscript = null; // one-shot
    _resumeTimer?.cancel();
    _resetVad();
    _turnPcm.clear(); // drop any half-captured new utterance so the next turn's STT is clean
    amplitude.value = 0;
    error = null;
    _resetSpeech(); // clear the local reply + highlight; the server reply replaces it
    userTranscript = t; // keep showing what was asked
    _set(VoiceState.thinking);
    ++_turnEpoch; // supersede any in-flight local attempt
    _abortSpeechStream(); // this turn's text is already decided
    _escalateText = null;
    // New turn for telemetry: the "speech end" is the moment the user asked
    // for the server retry (plan 0.2).
    _turnId = 'm-${DateTime.now().microsecondsSinceEpoch}';
    _speechEndMs = DateTime.now().millisecondsSinceEpoch;
    _firstAudioLogged = false;
    _serverProducedOutput = false;
    _sendServerTurn(text: t); // the begin_turn from _resetServerTurn is still open
  }

  Map<String, dynamic> _voiceModelFields() {
    final m = ModelSelection.instance.modelFor(VoiceSurface.voice);
    final p = ModelSelection.instance.providerFor(VoiceSurface.voice);
    return {
      if (m != null && m.isNotEmpty) 'model': m,
      if (p != null && p.isNotEmpty) 'model_provider': p,
    };
  }

  /// Handle [transcript] entirely on the device if we can. Returns true when
  /// the turn is DONE locally (a device action ran, or a local answer was
  /// spoken); false to escalate — [_escalateText] is already set by the caller.
  /// Never throws; bails early if the turn was superseded.
  ///
  /// Two layers, cheapest first:
  ///   1. [LocalExecutor] — a literal grammar over this phone's own skills. No
  ///      model, no network: "flashlight on" is done in tens of milliseconds
  ///      (plan 4.3).
  ///   2. [LocalRouter] — the on-device model answers conversation/knowledge.
  Future<bool> _tryLocalTurn(String transcript, int epoch) async {
    if (!LocalAiSettings.instance.enabledForVoice) return false;
    try {
      final decision = LocalExecutor.classify(transcript);
      debugLogLocalDecision(decision);
      if (decision is LocalRun) {
        return await _runLocalAction(decision, transcript, epoch);
      }

      final result = await app.localRouter.handle(transcript, VoiceSurface.voice);
      if (epoch != _turnEpoch) return false;
      debugPrint('[voice] route → ${result.runtimeType}'
          '${result is Escalate ? ' (${result.reason})' : ''}');
      switch (result) {
        case DirectAnswer():
          // Always stream the FULL reply (the guided-gen inline answer is a
          // short field that truncates long content).
          final reply = await _generateFull(transcript);
          if (epoch != _turnEpoch) return false;
          final spoken = reply.isEmpty ? 'At your service.' : reply;
          await _speakLocal(spoken);
          unawaited(_persistVoiceLocal(transcript, spoken));
          return true;
        case ToolCall(:final name, :final args, :final requiresConfirm, :final confirmation):
          // Outward/destructive actions defer to the server's approval flow.
          if (requiresConfirm) return false;
          final res = await app.runner.run(name, args);
          if (epoch != _turnEpoch) return false;
          // open_app that didn't actually launch (no iOS URL scheme for the app)
          // → escalate to the server instead of saying we opened it.
          if (localToolMissed(name, res)) {
            debugPrint('[voice] open_app miss → escalate to server');
            return false;
          }
          final ok = res.error == null;
          final say = ok
              ? (confirmation?.isNotEmpty == true
                  ? confirmation!
                  : _spokenConfirmation(name, res.result))
              : "Sorry, that didn't work.";
          await _speakLocal(say);
          unawaited(_persistVoiceLocal(transcript, say));
          return true;
        case Escalate():
          return false;
      }
    } catch (e) {
      debugPrint('[voice] local route failed, escalating: $e');
      return false;
    }
  }

  /// Run one allow-listed device action here and acknowledge it out loud with
  /// the PHONE's synthesizer (plan 4.3 + 4.4) — no server, no TTS round-trip.
  /// Returns false when the action didn't take, so the caller can escalate
  /// instead of claiming something happened.
  Future<bool> _runLocalAction(LocalRun plan, String transcript, int epoch) async {
    final outcome = await LocalExecutor(app.runner).execute(plan);
    if (epoch != _turnEpoch || !active) return outcome.ok;
    if (!outcome.ok) {
      debugPrint('[voice] local action ${plan.skill} failed → escalate');
      return false;
    }
    _logSpan('local_action_done');
    // The ack IS the reply for this turn — show it and speak it.
    if (await LocalTts.speak(outcome.spoken)) {
      _appendSpeech(outcome.spoken);
      _noteFirstAudio();
      _finalizeSpoken();
      _scheduleResumeListening();
    } else {
      // No native synthesizer on this build — fall back to the JARVIS voice.
      await _speakLocal(outcome.spoken);
    }
    // Async report so memory + the web transcript still see the action. The
    // server API has no "silent turn" flag, so we use the same
    // /api/session/append path on-device replies already use — it records the
    // turn WITHOUT running the agent (see SessionsApi.appendLocalTurn).
    unawaited(_persistVoiceLocal(
        transcript, LocalExecutor.reportLine(plan, outcome)));
    return true;
  }

  /// Speak [text] in the JARVIS voice. Split into sentence-sized chunks and
  /// TTS each as its OWN clip + karaoke segment — exactly like the server path.
  /// This is what makes the word-highlight advance (a single big clip leaves it
  /// stuck) and lets playback start after the first sentence. Offline (no TTS
  /// bytes) the reply stays on screen as text and we resume listening.
  Future<void> _speakLocal(String text) async {
    final epoch = _turnEpoch;
    final chunks = _splitForSpeech(_plainSpeech(text));
    if (chunks.isEmpty) {
      _scheduleResumeListening();
      return;
    }
    // Append karaoke segments up front (reply renders immediately, word count is
    // stable), recording each chunk's real seg index (a chunk that markdown-strips
    // to empty adds no segment — skip it, don't mis-tag/RangeError). Then
    // synthesize ALL clips CONCURRENTLY and WAIT for the whole set before enqueuing
    // any: enqueuing in index order as each resolves let a slow middle clip drain
    // the queue between clips, which flipped us to "thinking" and let the
    // resume-grace timer _finalizeSpoken() and abandon the reply (the "karaoke
    // doesn't work on-device" bug). Waiting first guarantees the queue never drains
    // mid-reply; the wait is the MAX (not sum) of the concurrent calls, and the
    // reply text is already on screen, so for short voice replies it's negligible.
    final tags = <int>[]; // seg index per synthesizable chunk
    final speak = <String>[];
    for (final chunk in chunks) {
      final before = _segs.length;
      _appendSpeech(chunk);
      if (_segs.length > before) {
        tags.add(_segs.length - 1);
        speak.add(chunk);
      }
    }
    if (epoch != _turnEpoch || !active) return;
    if (speak.isEmpty) {
      if (!_audio.isBusy) {
        _finalizeSpoken();
        _scheduleResumeListening();
      }
      return;
    }
    final clips = await Future.wait(<Future<List<int>>>[
      for (final c in speak)
        _voice.ttsBytes(text: c).catchError((Object e) {
          debugPrint('[voice] local JARVIS-voice TTS failed (offline?): $e');
          return <int>[];
        }),
    ]);
    if (epoch != _turnEpoch || !active) return;
    var anyAudio = false;
    for (var i = 0; i < clips.length; i++) {
      if (clips[i].isNotEmpty) {
        _segs[tags[i]].audioAssigned = true;
        _audio.enqueueMp3(Uint8List.fromList(clips[i]), tag: tags[i]);
        anyAudio = true;
      }
    }
    if (!anyAudio && !_audio.isBusy) {
      // Offline / no audio → reply is shown as text; resume listening.
      _finalizeSpoken();
      _scheduleResumeListening();
    }
  }

  /// Split a reply into sentence/line-sized chunks for per-clip TTS + karaoke,
  /// merging very short fragments so we don't make a clip per word.
  List<String> _splitForSpeech(String text) {
    final parts = text.split(RegExp(r'(?<=[.!?])\s+|\n+'));
    final out = <String>[];
    final buf = StringBuffer();
    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) continue;
      if (buf.isEmpty) {
        buf.write(p);
      } else if (buf.length < 40) {
        buf.write(' $p');
      } else {
        out.add(buf.toString());
        buf
          ..clear()
          ..write(p);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// Persist a completed on-device voice turn into the voice session so it
  /// shows on the web + other devices. Best-effort.
  Future<void> _persistVoiceLocal(String user, String assistant) async {
    try {
      final sid = await _ensureSession();
      await _sessions.appendLocalTurn(sid, user: user, assistant: assistant);
      // Live chats: tell the chat screen this session gained a turn so it shows
      // up without a manual reload.
      ChatSyncBus.instance.sessionChanged(sid);
    } catch (_) {}
  }

  /// Collect a full on-device reply (persona assistant prompt) into a string,
  /// for when the router answered locally but gave no inline text.
  Future<String> _generateFull(String userText) async {
    final req = LocalRequest(
      userText: userText,
      surface: VoiceSurface.voice,
      toolCatalogJson: '[]',
      tier: LocalAiTier.fullLocalFirst,
    );
    final buf = StringBuffer();
    final c = Completer<void>();
    OnDeviceAi.instance.generate(req).listen(
      (t) => buf.write(t),
      onError: (_) => c.complete(),
      onDone: () => c.complete(),
      cancelOnError: true,
    );
    await c.future;
    return buf.toString().trim();
  }

  String _spokenConfirmation(String name, Object? result) {
    if (result is Map) {
      final note = result['note'] ?? result['message'];
      if (note != null && note.toString().trim().isNotEmpty) {
        return note.toString();
      }
    }
    return 'Done — ${name.replaceAll('_', ' ')}.';
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
      _turnEpoch++; // invalidate any in-flight on-device local attempt
      _turnPcm.clear();
      _lastLocalTranscript = null; // user interrupted → no stale "Try on server"
      _sendJson({'type': 'interrupt'});
      unawaited(_audio.stop());
      unawaited(LocalTts.stop());
      _resetVad();
      _abortSpeechStream();
      unawaited(_startSpeechStream());
      _set(VoiceState.listening);
    }
  }

  void _resetVad() => _endpointer.reset();

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
        case 'latency':
          // Server-side span for this turn (plan 0.2). Mirror it into the
          // client log so one trace shows both sides.
          debugPrint(json.encode({
            'turn_id': (msg['turn_id'] ?? _turnId ?? '').toString(),
            'span': 'server:${(msg['span'] ?? 'turn').toString()}',
            'ms': (msg['ms'] is num) ? (msg['ms'] as num).toDouble() : 0.0,
          }));
          break;
        case 'escalation_result':
          // The slow lane finished after we already answered locally. Read it
          // out if the user is still on the voice screen (plan 4.4).
          _onEscalationResult((msg['text'] ?? '').toString());
          break;
        case 'assistant_text':
          // Reply is still in progress — cancel any pending resume and
          // show "thinking" until audio actually starts (playback flips
          // us to "speaking"). This keeps the orb from saying "listening"
          // while the reply is mid-flight.
          _resumeTimer?.cancel();
          _cancelThinkingWatchdog(); // real reply text is now arriving
          _serverProducedOutput = true;
          _appendSpeech((msg['text'] ?? '').toString());
          toolStatus = null;
          if (state != VoiceState.speaking) _set(VoiceState.thinking);
          break;
        case 'tool':
          _resumeTimer?.cancel();
          _serverProducedOutput = true;
          final name = (msg['name'] ?? 'tool').toString();
          final status = (msg['status'] ?? 'started').toString();
          toolStatus = status == 'completed' ? null : 'Running $name';
          if (state != VoiceState.speaking) _set(VoiceState.thinking);
          break;
        case 'audio_meta':
          _resumeTimer?.cancel();
          _serverProducedOutput = true;
          _inFormat = (msg['format'] ?? 'pcm_s16le').toString();
          _inRate = _asInt(msg['sample_rate']) ?? 24000;
          // Claim the karaoke segment NOW: PCM is played as it arrives (plan
          // 1.7), so there is no flush point left at which to pair them.
          _pcmTag = _claimSegTag();
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
        // Stream it straight into the player instead of buffering the whole
        // segment (plan 1.7) — the first ~160 ms starts playing immediately.
        _pcmTag ??= _claimSegTag(); // text may have landed after audio_meta
        _noteFirstAudio();
        _audio.appendPcm(Uint8List.fromList(data),
            sampleRate: _inRate, tag: _pcmTag);
      }
    } else {
      debugPrint('[voice] ws unexpected frame type: ${data.runtimeType}');
    }
  }

  /// Pair the incoming clip with the most recent text segment that doesn't yet
  /// have audio, so the karaoke highlight can time its words against it.
  int? _claimSegTag() {
    for (var i = _segs.length - 1; i >= 0; i--) {
      if (!_segs[i].audioAssigned) {
        _segs[i].audioAssigned = true;
        return i;
      }
    }
    return null;
  }

  /// End of one reply segment. MP3 is still whole-buffer (the decoder needs a
  /// complete file); PCM only has to close out the stream.
  void _flushSegment() {
    if (_inFormat == 'mp3') {
      if (_segMp3.isNotEmpty) {
        _noteFirstAudio();
        _audio.enqueueMp3(Uint8List.fromList(_segMp3), tag: _claimSegTag());
        _segMp3.clear();
      }
    } else {
      _audio.endPcmSegment(tag: _pcmTag);
      _pcmTag = null;
    }
  }

  /// Speak a late escalation result (plan 4.4): the fast lane already answered
  /// this turn locally and the slow lane came back with the real answer.
  void _onEscalationResult(String text) {
    final t = text.trim();
    if (t.isEmpty || !active) return;
    _resumeTimer?.cancel();
    _cancelThinkingWatchdog();
    _serverProducedOutput = true;
    unawaited(_speakLocal(t));
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
    // A real exchange happened (server persisted this turn) → tell the chat
    // screen to refresh so the voice turn appears live in Chats.
    if (_sessionId != null && assistantText.trim().isNotEmpty) {
      ChatSyncBus.instance.sessionChanged(_sessionId);
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
    _resumeTimer = Timer(const Duration(milliseconds: _resumeGraceMs), () {
      if (mode != VoiceMode.realtime || !active) return;
      if (_audio.isBusy) return; // a trailing segment is playing
      _finalizeSpoken(); // reply's done — light up any unspoken tail
      _resetVad();
      amplitude.value = 0;
      unawaited(_startSpeechStream()); // recognizer ready for the next utterance
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
    _pcmTag = null; // segment indices just went away
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
    // For an MP3 clip the audio queue fires this TWICE: once with an estimate at
    // play time, then again with the real decoded duration. The second call is a
    // schedule correction for the SAME segment — don't reset its progress.
    final isNew = tag != _curSeg;
    _curSeg = tag;
    final seg = _segs[tag];
    var ms = dur.inMilliseconds;
    if (ms <= 0) ms = seg.words.length * 300; // dur not yet known → ~200 wpm est
    seg.schedule(ms);
    if (isNew) seg.localSpoken = 0;
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
  /// Configure audio_session ONCE as the sole owner of the iOS audio session,
  /// like a phone/Discord call: .playAndRecord + .videoChat MODE. videoChat
  /// routes to the loud speaker (speakerphone) AND runs echo cancellation so
  /// the loud reply doesn't feed back into the live mic — which is how calling
  /// apps get full volume + simultaneous mic. (.defaultMode gave the quiet
  /// "call-volume" earpiece route — the original complaint.) Idempotent.
  Future<void> _ensureAudioSession() async {
    if (_session != null) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
                AVAudioSessionCategoryOptions.allowBluetooth |
                AVAudioSessionCategoryOptions.allowBluetoothA2dp |
                AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.videoChat,
      ));
      _interruptionSub =
          session.interruptionEventStream.listen(_onInterruption);
      _session = session;
    } catch (_) {
      // If audio_session isn't available, fall back silently — playback still
      // works via audioplayers' own context.
    }
  }

  /// A phone call / Siri / another app grabbed audio. iOS pauses our playback on
  /// `begin`; when it ends, re-grab the session so we can keep speaking.
  void _onInterruption(AudioInterruptionEvent event) {
    if (!event.begin) {
      unawaited(_session?.setActive(true) ?? Future<void>.value());
    }
  }

  Future<Stream<Uint8List>> _startMicStream() async {
    for (var attempt = 0;; attempt++) {
      try {
        final stream = await _recorder.startStream(_micConfig());
        // The voice session owns the audio session now — the background
        // keepalive (silent-audio) steps aside until the mic stops.
        AppLifecycle.voiceActive = true;
        return stream;
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
        // audio_session owns the AVAudioSession; record must NOT reconfigure or
        // deactivate it (doing so dropped the loud speaker route when the mic
        // stopped on background). See _ensureAudioSession.
        // ignore: deprecated_member_use
        iosConfig: IosRecordConfig(manageAudioSession: false),
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
    _cancelBgIdleTimeout();
    _cancelThinkingWatchdog();
    _abortSpeechStream();
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
    AppLifecycle.voiceActive = false;
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
  bool _foreground = true;

  /// A backgrounded realtime session sitting in `listening` with nobody talking
  /// is the worst-case battery drain (mic + audio session + WS all live). End it
  /// after this long so a forgotten session doesn't stream forever — but only
  /// when genuinely idle (never mid-reply or mid-utterance).
  Timer? _bgIdleTimer;
  static const Duration _bgIdleTimeout = Duration(seconds: 120);

  void _armBgIdleTimeout() {
    _bgIdleTimer?.cancel();
    _bgIdleTimer = Timer(_bgIdleTimeout, _onBgIdleTimeout);
  }

  void _cancelBgIdleTimeout() {
    _bgIdleTimer?.cancel();
    _bgIdleTimer = null;
  }

  void _onBgIdleTimeout() {
    _bgIdleTimer = null;
    if (_foreground || !active) return; // resumed / torn down → nothing to do
    // Only end a genuinely IDLE backgrounded session: waiting for the user to
    // speak, nobody mid-utterance, no reply in flight. `muted` counts as idle —
    // while muted the VAD is bypassed so the endpointer never clears, which
    // would otherwise re-arm forever and never reap a muted backgrounded
    // session.
    if (state == VoiceState.listening && (!_endpointer.speaking || muted)) {
      unawaited(stopAll());
    } else {
      _armBgIdleTimeout(); // busy now — re-check after another window
    }
  }

  /// App went to the background. We behave like a phone/Discord call: KEEP the
  /// mic, the audio session, the WebSocket, and playback all running (the app
  /// has the `audio` background mode, which lets an already-active recording
  /// session continue in the background). We deliberately do NOT stop/restart
  /// the mic — that's what reconfigured the session, dropped the loud speaker
  /// route to the quiet earpiece, degraded the volume each in/out cycle, and
  /// eventually wedged playback. iOS also won't let us re-START a recording
  /// session from the background, so stopping it would strand us anyway.
  Future<void> pauseForBackground() async {
    if (mode != VoiceMode.realtime || !active) return;
    _foreground = false;
    _cancelThinkingWatchdog(); // don't fire reassurance timers while backgrounded
    _armBgIdleTimeout(); // end a forgotten idle session after the timeout
  }

  /// App returned to the foreground. Nothing was torn down — just re-assert the
  /// session is active in case iOS deactivated it while we were away.
  Future<void> resumeFromBackground() async {
    _foreground = true;
    _cancelBgIdleTimeout();
    if (mode != VoiceMode.realtime || !active) return;
    await _session?.setActive(true);
  }

  /// Stop everything and return to idle (the Stop button / mode switch).
  Future<void> stopAll() async {
    _resumeTimer?.cancel();
    _cancelBgIdleTimeout();
    _cancelThinkingWatchdog();
    _lastLocalTranscript = null;
    _turnEpoch++; // invalidate any in-flight on-device local attempt
    _turnPcm.clear();
    _abortSpeechStream();
    unawaited(LocalTts.stop());
    await _teardownMic();
    await _closeWs();
    await _audio.stop();
    // Fully stopping → release the audio session (let other apps' audio resume).
    unawaited(_session?.setActive(false) ?? Future<void>.value());
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
    AppLifecycle.voiceActive = false;
    _resumeTimer?.cancel();
    _thinkingWatchdog?.cancel();
    _laTimer?.cancel();
    _cancelBgIdleTimeout();
    _interruptionSub?.cancel();
    unawaited(_session?.setActive(false) ?? Future<void>.value());
    try {
      app.ws.connected.removeListener(_onConnChanged);
    } catch (_) {}
    _abortSpeechStream();
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

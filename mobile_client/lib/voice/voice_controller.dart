import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/sessions.dart';
import '../api/voice.dart';
import '../services/api_client.dart';
import 'audio_queue.dart';
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
    );
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
  String assistantText = '';
  String? toolStatus; // e.g. "Running search_web"
  String? error;
  bool muted = false;

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
    notifyListeners();
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
    try {
      final list = await _sessions.list();
      for (final s in list) {
        final id = (s['session_id'] ?? '').toString();
        if (id.isNotEmpty) return _sessionId = id;
      }
    } catch (_) {}
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
    assistantText = '';
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
          if (text.isNotEmpty) {
            assistantText =
                assistantText.isEmpty ? text : '$assistantText\n\n$text';
          }
          final audioB64 = (ev['audio_base64'] ?? '').toString();
          if (audioB64.isNotEmpty) {
            _audio.enqueueMp3(base64.decode(audioB64));
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
    assistantText = '';
    toolStatus = null;
    _spoke = false;
    _silenceMs = 0;
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
    _set(VoiceState.thinking);
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
          notifyListeners();
          break;
        case 'assistant_text':
          // Reply is still in progress — cancel any pending resume and
          // show "thinking" until audio actually starts (playback flips
          // us to "speaking"). This keeps the orb from saying "listening"
          // while the reply is mid-flight.
          _resumeTimer?.cancel();
          final t = (msg['text'] ?? '').toString();
          assistantText =
              assistantText.isEmpty ? t : '$assistantText\n\n$t';
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
    if (_inFormat == 'mp3') {
      if (_segMp3.isNotEmpty) {
        _audio.enqueueMp3(Uint8List.fromList(_segMp3));
        _segMp3.clear();
      }
    } else {
      if (_segPcm.isNotEmpty) {
        _audio.enqueuePcm(Uint8List.fromList(_segPcm), sampleRate: _inRate);
        _segPcm.clear();
      }
    }
  }

  void _onRealtimeTurnEnd(String reason) {
    // Flush any audio that didn't get an explicit audio_end.
    _flushSegment();
    toolStatus = null;
    if (!active) return;
    // If audio is playing/queued, _onPlaybackIdle handles the resume once
    // it drains; otherwise (text-only / empty turn) schedule it now.
    if (!_audio.isBusy) _scheduleResumeListening();
  }

  /// A clip began playing — the assistant is talking.
  void _onPlaybackStart() {
    _resumeTimer?.cancel();
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
      _set(VoiceState.idle);
    }
  }

  void _scheduleResumeListening() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(milliseconds: _resumeGraceMs), () {
      if (mode != VoiceMode.realtime || !active) return;
      if (_audio.isBusy) return; // a trailing segment is playing
      _resetVad();
      amplitude.value = 0;
      _set(VoiceState.listening);
    });
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

  /// App went to the background. Keep the WebSocket and audio playback
  /// alive so the current reply finishes speaking, but stop capturing
  /// the mic so we're not recording while backgrounded. (record's stop()
  /// tears down its engine without deactivating the shared audio session,
  /// so playback keeps going.)
  Future<void> pauseForBackground() async {
    if (mode != VoiceMode.realtime || !active) return;
    _capturePaused = true;
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  /// App returned to the foreground — resume mic capture if we paused it.
  Future<void> resumeFromBackground() async {
    if (!_capturePaused) return;
    _capturePaused = false;
    if (mode != VoiceMode.realtime || !active) return;
    try {
      final stream = await _startMicStream();
      _micSub = stream.listen(_onRealtimeFrame);
      if (state != VoiceState.speaking) {
        _resetVad();
        _set(VoiceState.listening);
      }
    } catch (e) {
      _fail('Could not resume microphone: $e');
    }
  }

  /// Stop everything and return to idle (the Stop button / mode switch).
  Future<void> stopAll() async {
    _resumeTimer?.cancel();
    await _teardownMic();
    await _closeWs();
    await _audio.stop();
    _resetVad();
    amplitude.value = 0;
    if (state != VoiceState.error) _set(VoiceState.idle);
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
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

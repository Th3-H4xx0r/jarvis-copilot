import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Sequential playback of assistant audio clips. The voice backend hands
/// us either MP3 segments (quality mode, and the realtime MP3 fallback)
/// or raw 24 kHz PCM-S16LE frames (realtime). PCM is wrapped in a WAV
/// header; clips play back-to-back.
///
/// We write each clip to a temp file and play it via [DeviceFileSource]
/// rather than [BytesSource] — on iOS, BytesSource silently fails to
/// decode (play() "completes" instantly and you hear nothing).
///
/// [onIdle] fires when the queue drains (so the controller can return to
/// listening/idle); [onAmplitude] drives the orb during playback.
class AudioQueue {
  AudioQueue({
    this.onIdle,
    this.onAmplitude,
    this.onPlaybackStart,
    this.onClipStart,
    this.onPosition,
  }) {
    // Start in the mic-capable session config (playback coexists with the live
    // mic, which keeps iOS in `.playAndRecord`). When the app is backgrounded
    // the mic stops and we switch to a full-volume `.playback` config so the
    // reply doesn't drop to the quiet voice-chat route — see
    // useBackgroundPlayback.
    AudioPlayer.global.setAudioContext(_recordCtx);
    _player.setAudioContext(_recordCtx);
    _player.onPlayerComplete.listen((_) => _advance());
    // Live playback position — drives the karaoke word highlight. Only the
    // current clip's tag is reported so the controller can map position →
    // word within the right segment.
    _player.onPositionChanged.listen((p) {
      if (_currentTag != null) onPosition?.call(_currentTag, p);
    });
  }

  // Mic-capable session: playback coexists with the live mic. iOS forces this
  // onto `.playAndRecord` whenever the `record` package's mic + its
  // voice-processing (echo-cancel) unit is active.
  static final AudioContext _recordCtx = AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {
        AVAudioSessionOptions.defaultToSpeaker,
        AVAudioSessionOptions.mixWithOthers,
        AVAudioSessionOptions.allowBluetoothA2DP,
      },
    ),
    android: const AudioContextAndroid(
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.assistant,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  // Full-volume playback for when the mic is stopped (e.g. backgrounded mid
  // reply). `.playAndRecord` + the record package's voice-processing unit
  // leaves the iOS session on the attenuated voice-chat route, so a reply that
  // keeps playing after backgrounding gets quiet. `.playback` restores media
  // gain. (`.defaultToSpeaker` is only valid for `.playAndRecord`; `.playback`
  // routes to speaker by default, so it's omitted here.)
  static final AudioContext _playbackCtx = AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {
        AVAudioSessionOptions.mixWithOthers,
        AVAudioSessionOptions.allowBluetoothA2DP,
      },
    ),
    android: const AudioContextAndroid(
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.assistant,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  /// Switch the shared iOS audio session to full-volume `.playback` (mic
  /// stopped, e.g. app backgrounded) or back to the mic-capable config. Safe to
  /// call mid-clip — audioplayers re-applies the category immediately.
  Future<void> useBackgroundPlayback(bool background) async {
    final ctx = background ? _playbackCtx : _recordCtx;
    try {
      await AudioPlayer.global.setAudioContext(ctx);
      await _player.setAudioContext(ctx);
    } catch (_) {}
  }

  final void Function()? onIdle;
  final void Function(double amp)? onAmplitude;
  final void Function()? onPlaybackStart;

  /// Fired when a tagged clip begins, with the clip's playback [duration]
  /// (exact for PCM, queried for MP3). [tag] is the caller's clip id.
  final void Function(int? tag, Duration duration)? onClipStart;

  /// Fired ~5×/sec with the current clip's playback [position].
  final void Function(int? tag, Duration position)? onPosition;

  final AudioPlayer _player = AudioPlayer();
  final List<_Clip> _queue = [];
  bool _playing = false;
  bool _stopped = false;
  int _seq = 0;
  int? _currentTag; // tag of the clip currently playing (for position events)

  /// Enqueue an MP3 clip (raw bytes). [tag] (a segment id) lets the caller
  /// sync a word highlight to this clip's playback.
  void enqueueMp3(Uint8List bytes, {int? tag}) {
    if (bytes.isEmpty) return;
    debugPrint('[audio] enqueue MP3 ${bytes.length} bytes');
    _enqueue(_Clip(bytes, 'mp3', tag: tag));
  }

  /// Enqueue a raw PCM-S16LE clip at [sampleRate] (mono), wrapped in a
  /// WAV container. PCM duration is exact (computed from byte count).
  void enqueuePcm(Uint8List pcm, {int sampleRate = 24000, int? tag}) {
    if (pcm.isEmpty) return;
    debugPrint('[audio] enqueue PCM ${pcm.length} bytes @ ${sampleRate}Hz');
    final durMs = pcm.lengthInBytes ~/ 2 * 1000 ~/ sampleRate;
    _enqueue(_Clip(_wrapWav(pcm, sampleRate), 'wav', tag: tag, durationMs: durMs));
  }

  void _enqueue(_Clip clip) {
    if (_stopped) return;
    _queue.add(clip);
    if (!_playing) _advance();
  }

  Future<void> _advance() async {
    if (_stopped) return;
    if (_queue.isEmpty) {
      if (_playing) {
        _playing = false;
        onAmplitude?.call(0);
        onIdle?.call();
      }
      return;
    }
    _playing = true;
    final clip = _queue.removeAt(0);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/jc_voice_${_seq++}.${clip.ext}';
      final file = File(path);
      await file.writeAsBytes(clip.bytes, flush: true);
      // Drop position events while we swap clips so a trailing event from the
      // outgoing clip isn't attributed to the incoming one.
      _currentTag = null;
      await _player.stop();
      await _player.play(DeviceFileSource(path));
      _currentTag = clip.tag;
      onPlaybackStart?.call();
      onAmplitude?.call(0.6); // coarse "speaking" pulse for the orb
      debugPrint('[audio] playing $path (${clip.bytes.length}b)');
      // Announce the clip + its duration so the controller can schedule the
      // word highlight. PCM is exact; MP3 we ask the player (may be 0 until
      // it loads — the controller falls back to a words×rate estimate).
      if (clip.tag != null) {
        var durMs = clip.durationMs;
        if (durMs == null) {
          final d = await _player.getDuration();
          durMs = d?.inMilliseconds ?? 0;
        }
        onClipStart?.call(clip.tag, Duration(milliseconds: durMs));
      }
    } catch (e, st) {
      debugPrint('[audio] play() FAILED: $e\n$st');
      _advance(); // skip a bad clip rather than wedging the queue
    }
  }

  /// Drop anything queued and stop playback immediately (barge-in / new
  /// turn). Does NOT fire [onIdle].
  Future<void> stop() async {
    _queue.clear();
    _playing = false;
    _currentTag = null;
    try {
      await _player.stop();
    } catch (_) {}
    onAmplitude?.call(0);
  }

  bool get isBusy => _playing || _queue.isNotEmpty;

  Future<void> dispose() async {
    _stopped = true;
    _queue.clear();
    await _player.dispose();
  }

  /// Minimal 44-byte PCM WAV header + samples.
  static Uint8List _wrapWav(Uint8List pcm, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final dataLen = pcm.length;
    final out = BytesBuilder();
    void str(String s) => out.add(s.codeUnits);
    void u32(int v) => out.add([
          v & 0xFF,
          (v >> 8) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 24) & 0xFF,
        ]);
    void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);

    str('RIFF');
    u32(36 + dataLen);
    str('WAVE');
    str('fmt ');
    u32(16); // PCM fmt chunk size
    u16(1); // audio format = PCM
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bitsPerSample);
    str('data');
    u32(dataLen);
    out.add(pcm);
    return out.toBytes();
  }
}

class _Clip {
  _Clip(this.bytes, this.ext, {this.tag, this.durationMs});
  final Uint8List bytes;
  final String ext;
  final int? tag; // caller's segment id, for karaoke highlight sync
  final int? durationMs; // exact for PCM; null for MP3 (queried at play)
}

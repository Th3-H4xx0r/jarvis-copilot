import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'pcm_chunker.dart';
import 'pcm_stream_player.dart';

/// Sequential playback of assistant audio clips. The voice backend hands
/// us either MP3 segments (quality mode, and the realtime MP3 fallback)
/// or raw 24 kHz PCM-S16LE frames (realtime). PCM is wrapped in a WAV
/// header; clips play back-to-back.
///
/// We write each clip to a temp file and play it via [DeviceFileSource]
/// rather than [BytesSource] — on iOS, BytesSource silently fails to
/// decode (play() "completes" instantly and you hear nothing).
///
/// Realtime PCM does NOT wait for a whole segment: [appendPcm] streams it
/// through a [PcmChunker], so the first ~160 ms plays while the rest of the
/// sentence is still arriving (plan 1.7). The whole-buffer [enqueuePcm] and the
/// temp-file MP3 path are unchanged and remain the fallback.
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
    // Force playback onto the speaker and let it coexist with an active
    // recording session. In realtime the mic keeps the iOS session in
    // `.playAndRecord`, where playback otherwise routes to the (quiet)
    // earpiece.
    final ctx = AudioContext(
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
    AudioPlayer.global.setAudioContext(ctx);
    _player.setAudioContext(ctx);
    _player.onPlayerComplete.listen((_) => _advance());
    unawaited(_native.probe());
    // Live playback position — drives the karaoke word highlight. Only the
    // current clip's tag is reported so the controller can map position →
    // word within the right segment.
    _player.onPositionChanged.listen((p) {
      // Positions are reported SEGMENT-relative: a segment split into several
      // streamed chunks must still advance one continuous word schedule, so we
      // add the audio of this segment already played by earlier chunks.
      if (_currentTag != null) {
        onPosition?.call(
            _currentTag, p + Duration(milliseconds: _currentClipBaseMs));
      }
    });
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
  int _currentClipBaseMs = 0; // ms of this tag's audio played by earlier chunks
  PcmChunker? _chunker; // streaming cutter for the realtime PCM path (fallback)

  // ── Native gapless stream (plan 1.7, preferred) ─────────────────────────
  // One continuous render stream per reply instead of a temp file + play()
  // per slice — the per-slice player swap was the audible "cuts out every
  // second" stutter. Karaoke timing is derived from bytes fed + wall clock.
  final PcmStreamPlayer _native = PcmStreamPlayer();
  Future<void> _nativeChain = Future.value(); // keeps feed() order
  bool _nativeActive = false; // stream open and audio queued/playing
  bool _nativeEnded = false; // audio_end seen; go idle once playback catches up
  int? _nativeTag; // segment currently being fed
  int _nativeFedMs = 0; // total audio handed to the native player this stream
  int _nativeSegBaseMs = 0; // fed ms when the current segment began
  DateTime? _nativeStart; // wall clock at first feed
  Timer? _nativeTick;
  bool _nativePending = false; // a feed is queued on the chain but not yet run
  DateTime? _nativeLastFeed; // wall clock of the last feed (stall safety)
  static const int _kNativeTickMs = 100; // karaoke position cadence
  static const int _kNativeIdleGraceMs = 120; // wait for the last buffer to drain
  // Safety net: if audio_end never arrives (dropped frame, server error) go
  // idle once everything fed has played and nothing new came for this long.
  static const int _kNativeStallIdleMs = 1500;

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

  /// Stream realtime PCM for segment [tag] as it arrives. Plays the leading
  /// slice as soon as there's enough of it instead of waiting for the segment
  /// to finish (plan 1.7). Call [endPcmSegment] when `audio_end` lands.
  void appendPcm(Uint8List pcm, {int sampleRate = 24000, int? tag}) {
    if (_stopped || pcm.isEmpty) return;
    if (_native.available && _queue.isEmpty && !(_playing && !_nativeActive)) {
      _appendNative(pcm, sampleRate, tag);
      return;
    }
    final chunker = _chunkerFor(sampleRate);
    for (final chunk in chunker.add(pcm, tag: tag)) {
      _enqueueChunk(chunk);
    }
  }

  /// The segment is complete — play whatever is left of it.
  void endPcmSegment({int? tag}) {
    if (_stopped) return;
    if (_nativeActive || (_native.available && _nativePending)) {
      // Ordered behind the feeds already queued on the chain: a short reply's
      // audio_end can land before the first feed() has even opened the stream,
      // and marking "ended" ahead of that feed would be overwritten by it.
      _nativeChain = _nativeChain.then((_) {
        if (_nativeActive) _nativeEnded = true;
      });
      return;
    }
    final chunker = _chunker;
    if (chunker == null) return;
    for (final chunk in chunker.flush(tag: tag)) {
      _enqueueChunk(chunk);
    }
  }

  /// True while a segment is mid-stream (some audio buffered but not emitted).
  bool get hasPendingPcm =>
      _nativeActive || (_chunker?.bufferedBytes ?? 0) > 0;

  void _appendNative(Uint8List pcm, int sampleRate, int? tag) {
    final ms = pcm.lengthInBytes ~/ 2 * 1000 ~/ sampleRate;
    _nativePending = true;
    _nativeChain = _nativeChain.then((_) async {
      _nativePending = false;
      if (_stopped) return;
      if (!_nativeActive) {
        if (!await _native.start(sampleRate)) {
          // Native side refused — hand this chunk to the fallback path.
          for (final chunk in _chunkerFor(sampleRate).add(pcm, tag: tag)) {
            _enqueueChunk(chunk);
          }
          return;
        }
        _nativeActive = true;
        _nativeEnded = false;
        _playing = true;
        _nativeFedMs = 0;
        _nativeSegBaseMs = 0;
        _nativeStart = null;
        _nativeTag = tag;
      }
      if (tag != _nativeTag) {
        // Next sentence in the same stream: positions restart at its base.
        _nativeSegBaseMs = _nativeFedMs;
        _nativeTag = tag;
        _currentClipBaseMs = 0;
      }
      _nativeEnded = false;
      await _native.feed(pcm);
      _nativeFedMs += ms;
      _nativeLastFeed = DateTime.now();
      if (_nativeStart == null) {
        _nativeStart = DateTime.now();
        _currentTag = tag;
        onPlaybackStart?.call();
        onAmplitude?.call(0.6);
        _startNativeTick();
      }
      _currentTag = tag;
      // Running total for this segment so the karaoke schedule stretches as
      // more of the sentence arrives (a repeat tag = schedule correction).
      onClipStart?.call(tag, Duration(milliseconds: _nativeFedMs - _nativeSegBaseMs));
    });
  }

  void _startNativeTick() {
    _nativeTick?.cancel();
    _nativeTick = Timer.periodic(const Duration(milliseconds: _kNativeTickMs), (_) {
      final start = _nativeStart;
      if (!_nativeActive || start == null) return;
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final played = elapsed.clamp(0, _nativeFedMs);
      final tag = _nativeTag;
      if (tag != null) {
        onPosition?.call(tag, Duration(milliseconds: played - _nativeSegBaseMs));
      }
      if (_nativeEnded && elapsed >= _nativeFedMs + _kNativeIdleGraceMs) {
        _finishNative(fireIdle: true);
        return;
      }
      final last = _nativeLastFeed;
      if (!_nativePending &&
          last != null &&
          elapsed >= _nativeFedMs + _kNativeStallIdleMs &&
          DateTime.now().difference(last).inMilliseconds >= _kNativeStallIdleMs) {
        debugPrint('[audio] native stream: no audio_end — idling after stall');
        _finishNative(fireIdle: true);
      }
    });
  }

  void _finishNative({required bool fireIdle}) {
    _nativeTick?.cancel();
    _nativeTick = null;
    _nativeActive = false;
    _nativeEnded = false;
    _nativeStart = null;
    _nativeLastFeed = null;
    _nativeTag = null;
    _currentTag = null;
    _playing = false;
    unawaited(_native.stop());
    onAmplitude?.call(0);
    if (fireIdle) onIdle?.call();
  }

  PcmChunker _chunkerFor(int sampleRate) {
    final existing = _chunker;
    if (existing != null && existing.sampleRate == sampleRate) return existing;
    return _chunker = PcmChunker(sampleRate: sampleRate);
  }

  void _enqueueChunk(PcmChunk chunk) {
    if (chunk.bytes.isEmpty) return;
    _enqueue(_Clip(
      _wrapWav(chunk.bytes, chunk.sampleRate),
      'wav',
      tag: chunk.tag,
      durationMs: chunk.durationMs,
      // Announce the segment's running total, not this slice's length, so the
      // karaoke schedule stretches as more of the sentence arrives.
      segmentMs: chunk.segmentMsSoFar,
      baseMs: chunk.segmentMsSoFar - chunk.durationMs,
    ));
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
      _currentClipBaseMs = clip.baseMs;
      onPlaybackStart?.call();
      onAmplitude?.call(0.6); // coarse "speaking" pulse for the orb
      debugPrint('[audio] playing $path (${clip.bytes.length}b)');
      // Announce the clip + its duration so the controller can schedule the
      // word highlight. PCM is exact; MP3 we ask the player (may be 0 until
      // it loads — the controller falls back to a words×rate estimate).
      if (clip.tag != null) {
        if (clip.durationMs != null) {
          // PCM: exact duration, schedule the karaoke immediately. For a
          // streamed segment we report the running TOTAL so far — the
          // controller treats a repeat tag as a schedule correction, not a
          // restart, so the highlight keeps advancing across chunk seams.
          onClipStart?.call(clip.tag,
              Duration(milliseconds: clip.segmentMs ?? clip.durationMs!));
        } else {
          // MP3: getDuration() right after play() is unreliable on iOS (it returns
          // null or a stale/wrong value), which gives the karaoke a wrong word
          // schedule — the highlight sticks on the first word, then jumps to the
          // end when the next clip starts. Start on an estimate now (so _curSeg is
          // set and words can advance), then correct the schedule when the REAL
          // decoded duration arrives via onDurationChanged.
          onClipStart?.call(clip.tag, Duration.zero);
          _correctDuration(clip.tag);
        }
      }
    } catch (e, st) {
      debugPrint('[audio] play() FAILED: $e\n$st');
      _advance(); // skip a bad clip rather than wedging the queue
    }
  }

  /// MP3 duration isn't reliably known at play() time, so we re-fire [onClipStart]
  /// with the REAL decoded duration once it lands — from [AudioPlayer.onDurationChanged]
  /// (a getDuration() fallback covers the case it already fired). Applied at most
  /// once per clip, and only while [tag] is still the current clip.
  void _correctDuration(int? tag) {
    StreamSubscription<Duration>? sub;
    Timer? fallback;
    var applied = false;
    void apply(Duration? d) {
      if (applied) return;
      applied = true;
      sub?.cancel();
      fallback?.cancel();
      if (_currentTag == tag && d != null && d.inMilliseconds > 0) {
        onClipStart?.call(tag, d);
      }
    }

    sub = _player.onDurationChanged.listen(apply);
    fallback = Timer(const Duration(milliseconds: 350), () async {
      Duration? d;
      try {
        d = await _player.getDuration();
      } catch (_) {}
      apply(d);
    });
  }

  /// Drop anything queued and stop playback immediately (barge-in / new
  /// turn). Does NOT fire [onIdle].
  Future<void> stop() async {
    _queue.clear();
    _playing = false;
    _currentTag = null;
    _currentClipBaseMs = 0;
    // Barge-in/new turn: drop half-assembled audio too, or the tail of the
    // interrupted sentence would play after the user has already moved on.
    _chunker?.reset();
    if (_nativeActive) {
      await _native.flush();
      _finishNative(fireIdle: false);
    }
    try {
      await _player.stop();
    } catch (_) {}
    onAmplitude?.call(0);
  }

  bool get isBusy => _playing || _queue.isNotEmpty || _nativeActive;

  Future<void> dispose() async {
    _stopped = true;
    _nativeTick?.cancel();
    unawaited(_native.stop());
    _queue.clear();
    _chunker?.reset();
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
  _Clip(this.bytes, this.ext, {this.tag, this.durationMs, this.segmentMs, this.baseMs = 0});
  final Uint8List bytes;
  final String ext;
  final int? tag; // caller's segment id, for karaoke highlight sync
  final int? durationMs; // exact for PCM; null for MP3 (queried at play)

  /// Total audio of [tag] emitted so far, including this clip. Only set on the
  /// streaming PCM path; null means "this clip IS the whole segment".
  final int? segmentMs;

  /// Audio of [tag] played by EARLIER clips — added to every position report
  /// so the word highlight is continuous across a split segment.
  final int baseMs;
}

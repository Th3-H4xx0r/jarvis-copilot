
import 'package:flutter/services.dart';

/// Thin wrapper over the native gapless PCM player (plan 1.7):
/// iOS `PcmStreamBridge.swift` (AVAudioEngine) / Android `PcmStreamChannel.kt`
/// (streaming AudioTrack). Every arriving chunk is appended to ONE render
/// stream, so there are no player stop/start seams between chunks.
///
/// Degrades to "unavailable" (→ [AudioQueue] falls back to the temp-file
/// chunk path) when the platform side is missing or refuses to start.
class PcmStreamPlayer {
  PcmStreamPlayer({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel('jarviscopilot/pcm_stream');

  final MethodChannel _ch;
  bool _available = false;
  bool _probed = false;
  bool _open = false;

  /// True once [probe] confirmed the native side answers.
  bool get available => _available;

  /// True while a stream is open ([start] succeeded, [stop] not yet called).
  bool get isOpen => _open;

  Future<void> probe() async {
    if (_probed) return;
    _probed = true;
    try {
      _available = (await _ch.invokeMethod<bool>('ping')) == true;
    } catch (_) {
      _available = false;
    }
  }

  Future<bool> start(int sampleRate) async {
    try {
      _open = (await _ch.invokeMethod<bool>('start', {'sampleRate': sampleRate})) == true;
    } catch (_) {
      _open = false;
    }
    if (!_open) _available = false; // don't keep retrying a broken native side
    return _open;
  }

  Future<void> feed(Uint8List bytes) async {
    if (!_open || bytes.isEmpty) return;
    try {
      await _ch.invokeMethod('feed', {'bytes': bytes});
    } catch (_) {}
  }

  /// Drop queued audio, keep the stream open (barge-in).
  Future<void> flush() async {
    if (!_open) return;
    try {
      await _ch.invokeMethod('flush');
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}

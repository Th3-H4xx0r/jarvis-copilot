import 'dart:typed_data';

/// Cuts an arriving PCM-S16LE reply stream into playable pieces so the first
/// sample is audible while the rest of the sentence is still on the wire
/// (plan 1.7).
///
/// Before this, [AudioQueue] buffered a WHOLE segment (every frame between
/// `audio_meta` and `audio_end`) and only then wrote a temp file and played it —
/// so the phone sat silent for as long as the server took to finish sending
/// that sentence.
///
/// Pure Dart, no player, no files: the chunker only decides WHERE to cut, which
/// makes the ordering guarantee (the one thing that would be audible if it
/// broke) unit-testable.
class PcmChunker {
  PcmChunker({required this.sampleRate});

  /// Reply PCM sample rate (mono). Only used to convert bytes → milliseconds.
  final int sampleRate;

  // ── Cut sizes (plan 1.7) ──────────────────────────────────────────────────

  /// How much audio to gather before the FIRST clip of a segment. Small on
  /// purpose — this length IS the added first-word latency. 160 ms is enough
  /// for the player to have a decodable file and to survive a jittery link.
  static const int kFirstChunkMs = 160;

  /// Steady-state clip length once playback is running. Larger than the first
  /// chunk because by then we're ahead of the speaker: bigger clips mean fewer
  /// temp-file writes and fewer player swaps (each swap is a potential seam).
  static const int kChunkMs = 500;

  int? _tag;
  final BytesBuilder _buf = BytesBuilder(copy: true);
  int _emittedForTag = 0; // clips already emitted for the current segment
  int _segmentMs = 0; // total ms emitted for the current segment

  /// Bytes currently held back (not yet long enough to emit).
  int get bufferedBytes => _buf.length;

  /// Feed newly-arrived PCM for segment [tag]; returns whatever is now long
  /// enough to play, in arrival order.
  List<PcmChunk> add(Uint8List bytes, {int? tag}) {
    if (tag != _tag) _startSegment(tag);
    if (bytes.isNotEmpty) _buf.add(bytes);
    final out = <PcmChunk>[];
    while (true) {
      final want = _bytesFor(_emittedForTag == 0 ? kFirstChunkMs : kChunkMs);
      if (_buf.length < want) break;
      out.add(_take(want, segmentEnd: false));
    }
    return out;
  }

  /// The segment is complete — emit whatever is left, however short.
  List<PcmChunk> flush({int? tag}) {
    if (tag != _tag) return const [];
    // Drop a dangling half-sample; it can't be played and would desync the
    // next segment's byte stream.
    final usable = _buf.length - (_buf.length % 2);
    if (usable <= 0) {
      _buf.clear();
      return const [];
    }
    return [_take(usable, segmentEnd: true)];
  }

  /// Barge-in / new turn: throw away everything buffered so stale audio can
  /// never surface after the user has moved on.
  void reset() {
    _buf.clear();
    _tag = null;
    _emittedForTag = 0;
    _segmentMs = 0;
  }

  void _startSegment(int? tag) {
    _buf.clear();
    _tag = tag;
    _emittedForTag = 0;
    _segmentMs = 0;
  }

  PcmChunk _take(int byteCount, {required bool segmentEnd}) {
    final all = _buf.takeBytes(); // drains the builder
    final take = byteCount > all.length ? all.length : byteCount;
    final chunk = Uint8List.sublistView(all, 0, take);
    if (take < all.length) {
      _buf.add(Uint8List.sublistView(all, take));
    }
    final ms = (take ~/ 2) * 1000 ~/ sampleRate;
    _segmentMs += ms;
    _emittedForTag++;
    return PcmChunk(
      bytes: Uint8List.fromList(chunk),
      sampleRate: sampleRate,
      tag: _tag,
      durationMs: ms,
      segmentMsSoFar: _segmentMs,
      isSegmentEnd: segmentEnd,
    );
  }

  /// Whole 16-bit frames only — a split sample would click.
  int _bytesFor(int ms) {
    final samples = sampleRate * ms ~/ 1000;
    return samples * 2;
  }
}

/// One playable slice of a reply segment.
class PcmChunk {
  const PcmChunk({
    required this.bytes,
    required this.sampleRate,
    required this.tag,
    required this.durationMs,
    required this.segmentMsSoFar,
    required this.isSegmentEnd,
  });

  final Uint8List bytes;
  final int sampleRate;

  /// The karaoke segment this audio belongs to (see VoiceController._Seg).
  final int? tag;

  /// This slice's own duration.
  final int durationMs;

  /// Total audio emitted for [tag] INCLUDING this slice — the controller
  /// re-schedules the word highlight against this growing total, which is why
  /// splitting a segment doesn't strand the highlight on the first word.
  final int segmentMsSoFar;

  /// True for the last slice of a segment.
  final bool isSegmentEnd;
}

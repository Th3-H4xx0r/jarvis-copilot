import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/voice/pcm_chunker.dart';

const _rate = 24000; // the realtime reply rate the server sends

Uint8List _pcm(int ms, {int seed = 0}) {
  final samples = _rate * ms ~/ 1000;
  final out = Uint8List(samples * 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (seed + i) & 0xFF;
  }
  return out;
}

void main() {
  group('PcmChunker emits playable chunks as audio arrives', () {
    test('holds back until the first chunk is worth playing', () {
      final c = PcmChunker(sampleRate: _rate);
      expect(c.add(_pcm(50), tag: 0), isEmpty);
      final out = c.add(_pcm(150), tag: 0);
      expect(out, hasLength(1));
      expect(out.first.durationMs, greaterThanOrEqualTo(PcmChunker.kFirstChunkMs));
    });

    test('the first chunk is much shorter than the steady-state chunk', () {
      // This is the whole point of 1.7: the first audible sample must not wait
      // for a whole segment.
      expect(PcmChunker.kFirstChunkMs, lessThan(PcmChunker.kChunkMs));
      expect(PcmChunker.kFirstChunkMs, lessThanOrEqualTo(250));
    });

    test('later chunks use the larger steady-state size', () {
      final c = PcmChunker(sampleRate: _rate);
      c.add(_pcm(PcmChunker.kFirstChunkMs), tag: 0); // first chunk out
      expect(c.add(_pcm(PcmChunker.kChunkMs - 60), tag: 0), isEmpty);
      final out = c.add(_pcm(120), tag: 0);
      expect(out, hasLength(1));
      expect(out.first.durationMs, greaterThanOrEqualTo(PcmChunker.kChunkMs));
    });

    test('preserves byte order exactly across chunk boundaries', () {
      final c = PcmChunker(sampleRate: _rate);
      final input = <int>[];
      final emitted = <int>[];
      for (var i = 0; i < 12; i++) {
        final block = _pcm(90, seed: i * 7);
        input.addAll(block);
        for (final chunk in c.add(block, tag: 0)) {
          emitted.addAll(chunk.bytes);
        }
      }
      for (final chunk in c.flush(tag: 0)) {
        emitted.addAll(chunk.bytes);
      }
      expect(emitted, equals(input));
    });

    test('never splits a 16-bit sample', () {
      final c = PcmChunker(sampleRate: _rate);
      // Odd-length feeds: the dangling byte must be carried over, not emitted.
      for (var i = 0; i < 30; i++) {
        for (final chunk in c.add(Uint8List(2401), tag: 0)) {
          expect(chunk.bytes.length.isEven, isTrue);
        }
      }
    });
  });

  group('PcmChunker segment accounting drives the karaoke schedule', () {
    test('reports the running total duration for the segment', () {
      final c = PcmChunker(sampleRate: _rate);
      final a = c.add(_pcm(300), tag: 4).single;
      final b = c.add(_pcm(600), tag: 4).single;
      expect(a.segmentMsSoFar, a.durationMs);
      expect(b.segmentMsSoFar, a.durationMs + b.durationMs);
      expect(b.tag, 4);
    });

    test('flush ends the segment and emits the remainder', () {
      final c = PcmChunker(sampleRate: _rate);
      c.add(_pcm(200), tag: 1);
      final rest = c.flush(tag: 1);
      expect(rest, hasLength(1));
      expect(rest.single.isSegmentEnd, isTrue);
    });

    test('flush with nothing buffered emits nothing', () {
      final c = PcmChunker(sampleRate: _rate);
      c.add(_pcm(200), tag: 1);
      c.flush(tag: 1);
      expect(c.flush(tag: 1), isEmpty);
    });

    test('a new tag restarts the first-chunk fast start and the totals', () {
      final c = PcmChunker(sampleRate: _rate);
      c.add(_pcm(500), tag: 0);
      c.flush(tag: 0);
      final first = c.add(_pcm(PcmChunker.kFirstChunkMs + 10), tag: 1);
      expect(first, hasLength(1));
      expect(first.single.segmentMsSoFar, first.single.durationMs);
    });
  });

  group('PcmChunker interruption', () {
    test('reset drops buffered audio so a barge-in never plays late', () {
      final c = PcmChunker(sampleRate: _rate);
      c.add(_pcm(100), tag: 0); // below the first-chunk threshold, still buffered
      c.reset();
      expect(c.flush(tag: 0), isEmpty);
      expect(c.bufferedBytes, 0);
    });
  });
}

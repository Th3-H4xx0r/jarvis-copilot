import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/voice/endpointer.dart';

/// Feed `ms` of audio at amplitude `amp` in 20 ms frames, returning the first
/// non-`none` event (and stopping there) or `EndpointEvent.none`.
EndpointEvent _feed(Endpointer ep, double amp, int ms, {int frameMs = 20}) {
  var left = ms;
  while (left > 0) {
    final dt = left < frameMs ? left : frameMs;
    left -= dt;
    final ev = ep.update(amp, dt);
    if (ev != EndpointEvent.none) return ev;
  }
  return EndpointEvent.none;
}

void main() {
  group('Endpointer VAD hysteresis', () {
    test('does not start a turn below the speech threshold', () {
      final ep = Endpointer();
      expect(_feed(ep, Endpointer.kSpeechThreshold - 0.01, 2000),
          EndpointEvent.none);
      expect(ep.speaking, isFalse);
    });

    test('starts a turn once the speech threshold is crossed', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 300);
      expect(ep.speaking, isTrue);
    });

    test('energy between the two thresholds keeps the turn open (hysteresis)',
        () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1000);
      // Between silence(0.04) and speech(0.08) thresholds: still "voiced" —
      // the silence timer must not run.
      const mid = (Endpointer.kSpeechThreshold + Endpointer.kSilenceThreshold) / 2;
      expect(_feed(ep, mid, 3000), EndpointEvent.none);
      expect(ep.silenceMs, 0);
    });
  });

  group('Endpointer silence budgets', () {
    test('ends a normal utterance after the base silence window', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1500); // long, steady utterance → base budget
      expect(ep.requiredSilenceMs, Endpointer.kBaseSilenceMs);
      expect(_feed(ep, 0.0, Endpointer.kBaseSilenceMs - 40), EndpointEvent.none);
      expect(_feed(ep, 0.0, 80), EndpointEvent.endOfTurn);
    });

    test('a short utterance waits the extended silence window', () {
      final ep = Endpointer();
      // 400 ms of speech — under kShortUtteranceMs (600) → extended budget.
      _feed(ep, 0.30, 400);
      expect(ep.requiredSilenceMs, Endpointer.kExtendedSilenceMs);
      expect(_feed(ep, 0.0, Endpointer.kBaseSilenceMs + 100), EndpointEvent.none);
      expect(
          _feed(
              ep,
              0.0,
              Endpointer.kExtendedSilenceMs -
                  Endpointer.kBaseSilenceMs -
                  100 +
                  40),
          EndpointEvent.endOfTurn);
    });

    test('a rising-energy tail waits the extended silence window', () {
      final ep = Endpointer();
      _feed(ep, 0.15, 1000); // quiet body
      _feed(ep, 0.60, 200); // getting louder right before the pause
      expect(ep.requiredSilenceMs, Endpointer.kExtendedSilenceMs);
      expect(_feed(ep, 0.0, Endpointer.kBaseSilenceMs + 100), EndpointEvent.none);
    });

    test('a falling-energy tail uses the base silence window', () {
      final ep = Endpointer();
      _feed(ep, 0.60, 1000); // loud body
      _feed(ep, 0.15, 200); // trailing off
      expect(ep.requiredSilenceMs, Endpointer.kBaseSilenceMs);
      expect(_feed(ep, 0.0, Endpointer.kBaseSilenceMs + 40),
          EndpointEvent.endOfTurn);
    });

    test('speech resuming inside the silence window cancels the endpoint', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1000);
      expect(_feed(ep, 0.0, 300), EndpointEvent.none);
      _feed(ep, 0.30, 200); // picked back up
      expect(ep.silenceMs, 0);
      expect(_feed(ep, 0.0, 300), EndpointEvent.none); // budget restarted
    });
  });

  group('Endpointer guards', () {
    test('a sub-minimum blip never ends a turn and resets the detector', () {
      final ep = Endpointer();
      // 100 ms of noise — under kMinUtteranceMs (250).
      _feed(ep, 0.50, 100);
      expect(ep.speaking, isTrue);
      expect(_feed(ep, 0.0, 5000), EndpointEvent.none);
      expect(ep.speaking, isFalse, reason: 'blip is discarded, not endpointed');
    });

    test('ends the turn at the max utterance length even without silence', () {
      final ep = Endpointer();
      expect(_feed(ep, 0.50, Endpointer.kMaxUtteranceMs - 200),
          EndpointEvent.none);
      expect(_feed(ep, 0.50, 400), EndpointEvent.endOfTurn);
    });

    test('reset() returns the detector to the pre-speech state', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1000);
      _feed(ep, 0.0, 100);
      ep.reset();
      expect(ep.speaking, isFalse);
      expect(ep.speechMs, 0);
      expect(ep.silenceMs, 0);
    });

    test('voicedMs excludes the trailing silence', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1000);
      _feed(ep, 0.0, 200);
      expect(ep.voicedMs, 1000);
      expect(ep.speechMs, 1200);
    });

    test('negative or zero frame durations are ignored', () {
      final ep = Endpointer();
      expect(ep.update(0.5, -50), EndpointEvent.none);
      expect(ep.speechMs, 0);
    });
  });

  group('Endpointer.frameMsForPcm16', () {
    test('converts a PCM16 mono byte count to milliseconds', () {
      expect(Endpointer.frameMsForPcm16(3200, 16000), 100);
      expect(Endpointer.frameMsForPcm16(2048, 16000), 64);
      expect(Endpointer.frameMsForPcm16(0, 16000), 0);
    });
  });

  group('Endpointer is faster than the old fixed 1500 ms', () {
    test('a normal utterance endpoints well under the legacy constant', () {
      final ep = Endpointer();
      _feed(ep, 0.30, 1200);
      var silence = 0;
      while (silence < 1500) {
        if (ep.update(0.0, 20) == EndpointEvent.endOfTurn) break;
        silence += 20;
      }
      expect(silence, lessThan(1500));
      expect(silence, lessThanOrEqualTo(Endpointer.kBaseSilenceMs));
    });
  });
}

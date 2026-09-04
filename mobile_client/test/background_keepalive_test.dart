import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/background_keepalive.dart';

void main() {
  group('computeKeepaliveArmed (pure decision logic)', () {
    test('armed when enabled, paired, backgrounded, voice inactive', () {
      expect(
        computeKeepaliveArmed(
          enabled: true,
          paired: true,
          background: true,
          voiceActive: false,
        ),
        isTrue,
      );
    });

    test('disarmed when disabled', () {
      expect(
        computeKeepaliveArmed(
          enabled: false,
          paired: true,
          background: true,
          voiceActive: false,
        ),
        isFalse,
      );
    });

    test('disarmed when not paired', () {
      expect(
        computeKeepaliveArmed(
          enabled: true,
          paired: false,
          background: true,
          voiceActive: false,
        ),
        isFalse,
      );
    });

    test('disarmed when foregrounded (not needed)', () {
      expect(
        computeKeepaliveArmed(
          enabled: true,
          paired: true,
          background: false,
          voiceActive: false,
        ),
        isFalse,
      );
    });

    test('disarmed when voice controller already active (avoid session fight)', () {
      expect(
        computeKeepaliveArmed(
          enabled: true,
          paired: true,
          background: true,
          voiceActive: true,
        ),
        isFalse,
      );
    });

    test('disarmed when everything false', () {
      expect(
        computeKeepaliveArmed(
          enabled: false,
          paired: false,
          background: false,
          voiceActive: true,
        ),
        isFalse,
      );
    });
  });

  group('BackgroundKeepalive.sync coalescing', () {
    test('only invokes the platform channel when the armed state changes', () async {
      final calls = <bool>[];
      final ka = BackgroundKeepalive.forTest(setActive: (v) async {
        calls.add(v);
      });

      await ka.sync(enabled: true, paired: true, background: true, voiceActive: false);
      await ka.sync(enabled: true, paired: true, background: true, voiceActive: false);
      expect(calls, [true]); // second sync is a no-op: state unchanged

      await ka.sync(enabled: true, paired: true, background: false, voiceActive: false);
      expect(calls, [true, false]);

      await ka.setVoiceActive(true);
      // voice active alone shouldn't call setActive unless a background sync
      // re-evaluates; setVoiceActive re-runs sync with the last known inputs.
      expect(calls.last, false); // already disarmed (foreground), so no new call
    });

    test('setVoiceActive(true) disarms an armed keepalive using last known inputs', () async {
      final calls = <bool>[];
      final ka = BackgroundKeepalive.forTest(setActive: (v) async {
        calls.add(v);
      });
      await ka.sync(enabled: true, paired: true, background: true, voiceActive: false);
      expect(calls, [true]);

      await ka.setVoiceActive(true);
      expect(calls, [true, false]);

      await ka.setVoiceActive(false);
      expect(calls, [true, false, true]);
    });
  });
}

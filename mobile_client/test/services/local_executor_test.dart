import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/local_action_safety.dart';
import 'package:jarviscopilot_mobile/services/local_executor.dart';

/// The skills a typical Android build registers (see lib/skills/android.dart
/// + common.dart) — used so classification is checked against a REAL device's
/// capability set, not an imaginary one.
const _androidSkills = <String>{
  'open_app',
  'open_url',
  'notify',
  'clipboard_read',
  'clipboard_write',
  'vibrate',
  'take_photo',
  'play_audio',
  'set_alarm',
  'flashlight_on',
  'flashlight_off',
  'set_volume',
  'adjust_volume',
  'send_sms',
  'make_call',
};

/// iOS has no set_volume/adjust_volume — volume goes through phone_control.
const _iosSkills = <String>{
  'open_app',
  'open_url',
  'notify',
  'clipboard_read',
  'clipboard_write',
  'vibrate',
  'take_photo',
  'play_audio',
  'set_alarm',
  'flashlight_on',
  'flashlight_off',
  'phone_control',
  'send_sms',
  'make_call',
};

LocalDecision _cls(String text, {Set<String> skills = _androidSkills}) =>
    LocalExecutor.classify(text, skills: skills);

LocalRun _run(String text, {Set<String> skills = _androidSkills}) {
  final d = _cls(text, skills: skills);
  expect(d, isA<LocalRun>(), reason: 'expected a local action for "$text"');
  return d as LocalRun;
}

void _escalates(String text, {Set<String> skills = _androidSkills}) {
  final d = _cls(text, skills: skills);
  expect(d, isA<LocalSkip>(),
      reason: 'expected "$text" to escalate, got '
          '${d is LocalRun ? '${d.skill} ${d.args}' : d}');
}

void main() {
  group('LocalExecutor — device-local actions it runs without the server', () {
    test('open an app by name', () {
      final r = _run('open Chrome');
      expect(r.skill, 'open_app');
      expect(r.args['app'], 'Chrome');
      expect(r.ack, isNotEmpty);
    });

    test('open an app with filler words and an "app" suffix', () {
      final r = _run('hey, could you launch the Spotify app please');
      expect(r.skill, 'open_app');
      expect(r.args['app'], 'Spotify');
    });

    test('open a bare domain as a URL, not an app', () {
      final r = _run('open youtube.com');
      expect(r.skill, 'open_url');
      expect(r.args['url'], 'https://youtube.com');
    });

    test('open an explicit https URL', () {
      final r = _run('go to https://news.ycombinator.com');
      expect(r.skill, 'open_url');
      expect(r.args['url'], 'https://news.ycombinator.com');
    });

    test('flashlight on', () {
      expect(_run('turn on the flashlight').skill, 'flashlight_on');
      expect(_run('torch on').skill, 'flashlight_on');
    });

    test('flashlight off', () {
      expect(_run('turn off the flashlight').skill, 'flashlight_off');
    });

    test('set an absolute volume level on Android', () {
      final r = _run('set the volume to 40');
      expect(r.skill, 'set_volume');
      expect(r.args['level'], 40);
    });

    test('set an absolute volume level on iOS goes through phone_control', () {
      final r = _run('set the volume to 40%', skills: _iosSkills);
      expect(r.skill, 'phone_control');
      expect(r.args['action'], 'volume');
      expect(r.args['value'], '40');
    });

    test('relative volume change', () {
      final r = _run('turn the volume up');
      expect(r.skill, 'adjust_volume');
      expect(r.args['direction'], 'up');
    });

    test('volume level is clamped to 0..100', () {
      expect(_run('set the volume to 480').args['level'], 100);
    });

    test('vibrate', () {
      expect(_run('vibrate the phone').skill, 'vibrate');
    });

    test('timer in minutes becomes a relative alarm', () {
      final r = _run('set a timer for 10 minutes');
      expect(r.skill, 'set_alarm');
      expect(r.args['in_minutes'], 10);
    });

    test('an alarm at a clock time becomes an absolute alarm', () {
      final r = _run('set an alarm for 7:30 am');
      expect(r.skill, 'set_alarm');
      expect(r.args['hour'], 7);
      expect(r.args['minute'], 30);
    });

    test('pm clock times are converted to 24h', () {
      final r = _run('wake me up at 6 pm');
      expect(r.args['hour'], 18);
      expect(r.args['minute'], 0);
    });

    test('write the clipboard', () {
      final r = _run('copy hello world to my clipboard');
      expect(r.skill, 'clipboard_write');
      expect(r.args['text'], 'hello world');
    });

    test('read the clipboard', () {
      expect(_run("what's on my clipboard").skill, 'clipboard_read');
    });

    test('take a photo', () {
      expect(_run('take a photo').skill, 'take_photo');
    });

    test('local notification', () {
      final r = _run('notify me that the pasta is ready');
      expect(r.skill, 'notify');
      expect(r.args['title'], 'the pasta is ready');
    });
  });

  group('LocalExecutor — everything else escalates to the server', () {
    test('another device', () {
      _escalates('open Chrome on my Mac');
      _escalates('turn on the flashlight on my watch');
    });

    test('messages and contacts', () {
      _escalates("text Mom I'm late");
      _escalates('send Sarah a message saying hi');
      _escalates('call Dad');
      _escalates("what's Priya's number");
    });

    test('money / commerce', () {
      _escalates('order me an Uber');
      _escalates('pay Sam 20 dollars');
      _escalates('buy the AirPods in my cart');
    });

    test('live data is not a device action', () {
      _escalates("what's the weather");
      _escalates('give me the morning brief');
      _escalates("what's on my calendar today");
    });

    test('ambiguous target', () {
      _escalates('open it');
      _escalates('open that thing');
      _escalates('set the volume');
    });

    test('destructive verbs never run locally', () {
      _escalates('delete my photos');
      _escalates('erase the clipboard history');
    });

    test('a skill this device does not have escalates', () {
      _escalates('turn on the flashlight', skills: {'open_app', 'vibrate'});
      _escalates('set the volume to 40', skills: {'open_app'});
    });

    test('empty / noise input escalates', () {
      _escalates('   ');
      _escalates('uh');
    });

    test('play requests need the server (media accounts, not a local clip)', () {
      _escalates('play some jazz');
      _escalates('play Bohemian Rhapsody on Spotify');
    });
  });

  group('LocalExecutor — negated commands never run locally', () {
    test('flashlight', () => _escalates("don't turn on the flashlight"));
    test('vibrate', () => _escalates('do not vibrate the phone'));
    test('alarm', () => _escalates('never set an alarm for 7am'));
    test('photo', () => _escalates('stop taking photos'));
    test('clipboard', () => _escalates('no need to copy this to my clipboard'));
    test('volume', () => _escalates("don't set the volume to 40"));
  });

  group('LocalExecutor — permission questions never run locally', () {
    test('flashlight', () => _escalates('should I turn on the flashlight?'));
    test('alarm', () => _escalates('should I set an alarm for 7am?'));
    test('vibrate', () => _escalates('can I vibrate the phone?'));
    test('volume', () => _escalates('do I need to set the volume to 40?'));
    test('photo', () => _escalates('is it ok to take a photo?'));
    test('clipboard',
        () => _escalates('am I supposed to copy this to my clipboard?'));
  });

  group('LocalExecutor — polite positive imperatives still run', () {
    test('a "?" phrased request that is actually a command still runs', () {
      expect(_run('could you turn on the flashlight?').skill, 'flashlight_on');
    });
    test('a please-prefixed alarm still runs', () {
      final r = _run('please set an alarm for 7:30 am');
      expect(r.skill, 'set_alarm');
    });
  });

  group('LocalExecutor — third-party targets escalate (plan review IMPORTANT)', () {
    test('an alarm for someone else', () {
      _escalates('set an alarm for Dad at 6am');
    });
    test('a flashlight request for someone else', () {
      _escalates('turn on the flashlight for Mom');
    });
    test('a timer duration is not a third-party target', () {
      final r = _run('set a timer for 10 minutes');
      expect(r.skill, 'set_alarm');
    });
    test('"for me" is not a third-party target', () {
      final r = _run('open Chrome for me');
      expect(r.skill, 'open_app');
    });
    test('a day name is not a third-party target', () {
      final r = _run('set an alarm for 6am');
      expect(r.skill, 'set_alarm');
    });
  });

  group('LocalExecutor safety invariants', () {
    test('every skill it can emit is on the local allow-list', () {
      const utterances = [
        'open Chrome',
        'open youtube.com',
        'turn on the flashlight',
        'turn off the flashlight',
        'set the volume to 40',
        'turn the volume up',
        'vibrate the phone',
        'set a timer for 10 minutes',
        'copy hello to my clipboard',
        "what's on my clipboard",
        'take a photo',
        'notify me that dinner is ready',
      ];
      for (final u in utterances) {
        final d = LocalExecutor.classify(u, skills: _androidSkills);
        if (d is LocalRun) {
          expect(isLocallyAllowed(d.skill), isTrue,
              reason: '"$u" produced non-allow-listed skill ${d.skill}');
        }
      }
      // …and on iOS, where volume is a phone_control verb.
      final ios = LocalExecutor.classify('set the volume to 40', skills: _iosSkills);
      expect(isLocallyAllowed((ios as LocalRun).skill), isTrue);
    });

    test('the allow-list excludes outward and destructive skills', () {
      for (final name in ['send_sms', 'make_call', 'share_text', 'run_shortcut']) {
        expect(isLocallyAllowed(name), isFalse, reason: name);
      }
    });

    test('a skip carries a reason for the escalation log', () {
      final d = _cls('open Chrome on my Mac');
      expect((d as LocalSkip).reason, isNotEmpty);
    });
  });
}

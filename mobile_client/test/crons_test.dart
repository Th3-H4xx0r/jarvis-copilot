import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/crons.dart';
import 'package:jarviscopilot_mobile/theme.dart';

void main() {
  group('cronJobId', () {
    test('prefers job_id over id', () {
      expect(cronJobId({'job_id': 'abc', 'id': 'xyz'}), 'abc');
    });
    test('falls back to id', () {
      expect(cronJobId({'id': 'xyz'}), 'xyz');
    });
    test('empty when neither present', () {
      expect(cronJobId({}), '');
    });
  });

  group('cronStatusKey', () {
    test('flat status string wins', () {
      expect(cronStatusKey({'status': 'Running'}), 'running');
    });
    test('paused state', () {
      expect(cronStatusKey({'state': 'paused', 'enabled': true}), 'paused');
    });
    test('disabled (enabled=false) → off', () {
      expect(
        cronStatusKey({'state': 'scheduled', 'enabled': false}),
        'off',
      );
    });
    test('last_status error → error', () {
      expect(
        cronStatusKey({
          'state': 'scheduled',
          'enabled': true,
          'last_status': 'error',
          'next_run_at': '2026-01-01T00:00:00',
        }),
        'error',
      );
    });
    test('error with no next run → needs_attention', () {
      expect(
        cronStatusKey({'state': 'error', 'enabled': true}),
        'needs_attention',
      );
    });
    test('default scheduled → scheduled', () {
      expect(
        cronStatusKey({'state': 'scheduled', 'enabled': true}),
        'scheduled',
      );
    });
    test('empty job → active', () {
      expect(cronStatusKey({}), 'active');
    });
  });

  group('cronStatusLabel', () {
    test('known keys', () {
      expect(cronStatusLabel('running'), 'RUNNING');
      expect(cronStatusLabel('paused'), 'PAUSED');
      expect(cronStatusLabel('off'), 'OFF');
      expect(cronStatusLabel('error'), 'ERROR');
      expect(cronStatusLabel('needs_attention'), 'NEEDS ATTENTION');
      expect(cronStatusLabel('scheduled'), 'ACTIVE');
      expect(cronStatusLabel('active'), 'ACTIVE');
    });
    test('unknown key uppercases', () {
      expect(cronStatusLabel('whatever'), 'WHATEVER');
    });
    test('empty key defaults to ACTIVE', () {
      expect(cronStatusLabel(''), 'ACTIVE');
    });
  });

  group('cronStatusColor', () {
    test('running is primaryBlue', () {
      expect(cronStatusColor('running'), JcTheme.primaryBlue);
    });
    test('paused is muted', () {
      expect(cronStatusColor('paused'), JcTheme.muted);
    });
    test('error/needs are danger', () {
      expect(cronStatusColor('error'), JcTheme.danger);
      expect(cronStatusColor('needs_attention'), JcTheme.danger);
    });
    test('default is success', () {
      expect(cronStatusColor('scheduled'), JcTheme.success);
      expect(cronStatusColor('anything'), JcTheme.success);
    });
    test('returns a Color', () {
      expect(cronStatusColor('running'), isA<Color>());
    });
  });

  group('cronIsPaused', () {
    test('true for paused state', () {
      expect(cronIsPaused({'state': 'paused'}), isTrue);
    });
    test('false otherwise', () {
      expect(cronIsPaused({'state': 'scheduled', 'enabled': true}), isFalse);
    });
  });

  group('cronSchedule', () {
    test('prefers schedule_display', () {
      expect(
        cronSchedule({'schedule_display': 'every day', 'schedule': {}}),
        'every day',
      );
    });
    test('flat string schedule', () {
      expect(cronSchedule({'schedule': '*/5 * * * *'}), '*/5 * * * *');
    });
    test('dict schedule with expression', () {
      expect(
        cronSchedule({
          'schedule': {'expression': '0 9 * * *'}
        }),
        '0 9 * * *',
      );
    });
    test('empty when nothing usable', () {
      expect(cronSchedule({}), '');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/server_logs.dart';

void main() {
  group('logSeverity', () {
    test('an ERROR line is error', () {
      expect(logSeverity('2026-06-21 ERROR something blew up'), 'error');
      expect(logSeverity('Traceback (most recent call last):'), 'error');
      expect(logSeverity('raised an Exception'), 'error');
      expect(logSeverity('CRITICAL failure'), 'error');
      // Case-insensitive.
      expect(logSeverity('an error occurred'), 'error');
    });

    test('a WARNING line is warn', () {
      expect(logSeverity('2026-06-21 WARNING low disk'), 'warn');
      expect(logSeverity('WARN: retrying'), 'warn');
      expect(logSeverity('a warning was issued'), 'warn');
    });

    test('a plain / INFO line is info', () {
      expect(logSeverity('INFO server started'), 'info');
      expect(logSeverity('just a plain line'), 'info');
      expect(logSeverity(''), 'info');
    });
  });

  group('parseLogLines', () {
    test('from {lines: [...]}', () {
      final out = parseLogLines({
        'lines': ['a', 'b', 'c'],
      });
      expect(out, ['a', 'b', 'c']);
    });

    test('from {content: "a\\nb"}', () {
      final out = parseLogLines({'content': 'a\nb'});
      expect(out, ['a', 'b']);
    });

    test('content with trailing newline drops the empty final line', () {
      final out = parseLogLines({'content': 'a\nb\n'});
      expect(out, ['a', 'b']);
    });

    test('bare list', () {
      expect(parseLogLines(['x', 'y']), ['x', 'y']);
    });

    test('missing / unknown shape yields empty', () {
      expect(parseLogLines({'nope': 1}), isEmpty);
      expect(parseLogLines(42), isEmpty);
      expect(parseLogLines(null), isEmpty);
    });
  });

  test('serverLogFiles matches the backend whitelist', () {
    expect(serverLogFiles, ['agent', 'errors', 'gateway']);
  });
}

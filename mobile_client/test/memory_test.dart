import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/memory.dart';

void main() {
  group('formatMemoryMtime', () {
    test('numeric epoch (seconds) → non-empty human string', () {
      // 2021-06-20T17:33:20Z — the actual rendering is local-time dependent,
      // so we only assert it produced something non-empty and year-bearing.
      final out = formatMemoryMtime(1624210400);
      expect(out, isNotEmpty);
      expect(out, contains('2021'));
    });

    test('numeric epoch as double works too', () {
      expect(formatMemoryMtime(1624210400.123), isNotEmpty);
    });

    test('numeric epoch as numeric string is parsed', () {
      final out = formatMemoryMtime('1624210400');
      expect(out, isNotEmpty);
      expect(out, contains('2021'));
    });

    test('null → empty string', () {
      expect(formatMemoryMtime(null), '');
    });

    test('empty / whitespace string → empty string', () {
      expect(formatMemoryMtime(''), '');
      expect(formatMemoryMtime('   '), '');
    });

    test('zero / negative epoch → empty string', () {
      expect(formatMemoryMtime(0), '');
      expect(formatMemoryMtime(-5), '');
    });

    test('already-formatted non-numeric string is returned as-is', () {
      const pretty = 'Jun 21, 2026, 3:07 PM';
      expect(formatMemoryMtime(pretty), pretty);
    });

    test('unexpected type → empty string', () {
      expect(formatMemoryMtime(<String, dynamic>{}), '');
      expect(formatMemoryMtime([1, 2, 3]), '');
    });

    test('formatted output has the expected month/comma shape', () {
      final out = formatMemoryMtime(1624210400);
      // "<Mon> <day>, <year>, <h>:<mm> <AM|PM>"
      expect(out, matches(RegExp(r'^[A-Z][a-z]{2} \d{1,2}, \d{4}, '
          r'\d{1,2}:\d{2} (AM|PM)$')));
    });
  });
}

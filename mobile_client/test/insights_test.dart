import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/insights.dart';

void main() {
  group('formatTokenCount', () {
    test('inserts thousands separators', () {
      expect(formatTokenCount(1234), '1,234');
      expect(formatTokenCount(1234567), '1,234,567');
    });
    test('leaves small numbers unchanged', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(42), '42');
      expect(formatTokenCount(999), '999');
    });
    test('handles negatives', () {
      expect(formatTokenCount(-1234), '-1,234');
    });
    test('coerces numeric strings and null', () {
      expect(formatTokenCount('1234'), '1,234');
      expect(formatTokenCount('1,234'), '1,234');
      expect(formatTokenCount('\$2,500'), '2,500');
      expect(formatTokenCount(null), '0');
      expect(formatTokenCount('nope'), '0');
    });
    test('rounds non-integers', () {
      expect(formatTokenCount(1234.7), '1,235');
    });
  });

  group('formatTokensCompact', () {
    test('compacts thousands and millions', () {
      expect(formatTokensCompact(0), '0');
      expect(formatTokensCompact(999), '999');
      expect(formatTokensCompact(1500), '1.5K');
      expect(formatTokensCompact(2500000), '2.5M');
    });
  });

  group('formatCost', () {
    test('shows em dash at or below zero', () {
      expect(formatCost(0), '—');
      expect(formatCost(null), '—');
      expect(formatCost(-1), '—');
    });
    test('4 decimals under a dollar, 2 over', () {
      expect(formatCost(0.1234), '\$0.1234');
      expect(formatCost(12.5), '\$12.50');
    });
    test('parses string costs', () {
      expect(formatCost('\$3.50'), '\$3.50');
    });
  });

  group('parseModelStats', () {
    test('parses the real list-of-objects shape', () {
      final rows = parseModelStats([
        {
          'model': 'claude-code',
          'sessions': 5,
          'input_tokens': 100,
          'output_tokens': 50,
          'total_tokens': 150,
          'cost': 0.42,
        },
        {
          'model': 'sonnet',
          'sessions': 2,
          'total_tokens': 30,
          'cost': 0.0,
        },
      ]);
      expect(rows.length, 2);
      expect(rows.first['model'], 'claude-code');
      expect(rows.first['total_tokens'], 150);
    });

    test('tolerates a legacy map-keyed-by-model shape', () {
      final rows = parseModelStats({
        'claude-code': {'sessions': 3, 'total_tokens': 99},
        'unknown': {'sessions': 1, 'total_tokens': 1},
      });
      expect(rows.length, 2);
      expect(rows.map((r) => r['model']), containsAll(['claude-code', 'unknown']));
    });

    test('defaults a missing model name to "unknown"', () {
      final rows = parseModelStats([
        {'sessions': 1, 'total_tokens': 5},
      ]);
      expect(rows.single['model'], 'unknown');
    });

    test('returns empty for null / non-collection input', () {
      expect(parseModelStats(null), isEmpty);
      expect(parseModelStats(42), isEmpty);
      expect(parseModelStats('x'), isEmpty);
    });
  });

  group('parseRows', () {
    test('normalises a list of maps', () {
      final rows = parseRows([
        {'date': '2026-06-01', 'input_tokens': 10},
        {'date': '2026-06-02', 'input_tokens': 20},
      ]);
      expect(rows.length, 2);
      expect(rows[1]['input_tokens'], 20);
    });
    test('returns empty for non-list input', () {
      expect(parseRows(null), isEmpty);
      expect(parseRows({'messages': []}), isEmpty);
    });
  });

  group('insightsNum', () {
    test('coerces ints, doubles, strings and null', () {
      expect(insightsNum(5), 5);
      expect(insightsNum(2.5), 2.5);
      expect(insightsNum('7'), 7);
      expect(insightsNum('\$1,000'), 1000);
      expect(insightsNum(null), 0);
    });
  });
}

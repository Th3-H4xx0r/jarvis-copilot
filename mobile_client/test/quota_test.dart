import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/quota.dart';
import 'package:jarviscopilot_mobile/widgets/quota_card.dart';

void main() {
  group('QuotaProvider/QuotaWindow parsing', () {
    test('parses providers and windows from /api/provider/quota/all', () {
      final raw = {
        'provider': 'claude-code',
        'display_name': 'Claude Code',
        'plan': 'Max',
        'windows': [
          {
            'label': 'Current session',
            'used_percent': 45.0,
            'remaining_percent': 55.0,
            'reset_at': '2030-03-17T17:30:00Z',
            'detail': null,
          },
          {
            'label': 'Current week',
            'used_percent': 18,
            'remaining_percent': 82,
            'reset_at': null,
            'detail': 'Opus + Sonnet',
          },
        ],
        'details': ['Extra usage: 1.20 / 50.00 USD', ''],
        'fetched_at': '2030-03-17T12:30:00Z',
      };

      final p = QuotaProvider.fromJson(Map<String, dynamic>.from(raw));

      expect(p.provider, 'claude-code');
      expect(p.displayName, 'Claude Code');
      expect(p.plan, 'Max');
      expect(p.windows, hasLength(2));
      expect(p.windows[0].label, 'Current session');
      expect(p.windows[0].usedPercent, 45.0);
      expect(p.windows[0].remainingPercent, 55.0);
      expect(p.windows[0].resetAt, isNotNull);
      expect(p.windows[1].usedPercent, 18.0);
      expect(p.windows[1].detail, 'Opus + Sonnet');
      // empty detail string is dropped
      expect(p.details, ['Extra usage: 1.20 / 50.00 USD']);
      expect(p.fetchedAt, isNotNull);
    });

    test('tolerates missing fields and a null used_percent', () {
      final p = QuotaProvider.fromJson({
        'provider': 'openai-codex',
        'windows': [
          {'label': 'Session', 'used_percent': null},
          {'label': ''}, // dropped — no label
        ],
      });
      expect(p.displayName, 'openai-codex');
      expect(p.windows, hasLength(1));
      expect(p.windows[0].usedPercent, isNull);
    });
  });

  group('QuotaUsageCard widget', () {
    Future<void> pumpCard(WidgetTester tester, QuotaLoader loader) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: QuotaUsageCard(loader: loader)),
      ));
      await tester.pump(); // resolve the loader Future + setState
      await tester.pump();
    }

    testWidgets('renders a bar + percentage for every window', (tester) async {
      await pumpCard(tester, ({bool refresh = false}) async => [
            const QuotaProvider(
              provider: 'claude-code',
              displayName: 'Claude Code',
              windows: [
                QuotaWindow(label: 'Current session', usedPercent: 45, remainingPercent: 55),
                QuotaWindow(label: 'Current week', usedPercent: 18, remainingPercent: 82),
              ],
            ),
            const QuotaProvider(
              provider: 'openai-codex',
              displayName: 'OpenAI Codex',
              windows: [
                QuotaWindow(label: 'Session', usedPercent: 61, remainingPercent: 39),
              ],
            ),
          ]);

      expect(find.text('Quota & Usage'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('OpenAI Codex'), findsOneWidget);
      // percentages (used)
      expect(find.text('45%'), findsOneWidget);
      expect(find.text('18%'), findsOneWidget);
      expect(find.text('61%'), findsOneWidget);
      // one progress bar per window (3 total)
      expect(find.byType(FractionallySizedBox), findsNWidgets(3));
      // ...and the fill must actually have height. Regression: a childless
      // DecoratedBox inside a width-only FractionallySizedBox collapsed to 0px.
      final fsb =
          tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox).first);
      expect(fsb.heightFactor, 1.0);
      final fillSize = tester.getSize(find
          .descendant(
            of: find.byType(FractionallySizedBox).first,
            matching: find.byType(DecoratedBox),
          )
          .first);
      expect(fillSize.height, greaterThan(0));
      expect(fillSize.width, greaterThan(0)); // 45% window → non-zero fill
    });

    testWidgets('null used_percent shows "—" and an empty bar', (tester) async {
      await pumpCard(tester, ({bool refresh = false}) async => [
            const QuotaProvider(
              provider: 'openai-codex',
              displayName: 'OpenAI Codex',
              windows: [QuotaWindow(label: 'Session')],
            ),
          ]);

      expect(find.text('—'), findsOneWidget);
      final bar = tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox));
      expect(bar.widthFactor, 0.0);
    });

    testWidgets('empty provider list shows an empty-state note', (tester) async {
      await pumpCard(tester, ({bool refresh = false}) async => const []);
      expect(find.textContaining('No quota-capable providers'), findsOneWidget);
    });

    testWidgets('loader error shows a retry note', (tester) async {
      await pumpCard(tester, ({bool refresh = false}) async => throw Exception('boom'));
      expect(find.textContaining('Couldn’t load usage'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}

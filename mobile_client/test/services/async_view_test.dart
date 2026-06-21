import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/widgets/async_view.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders builder output once loaded', (tester) async {
    await tester.pumpWidget(host(
      AsyncView<List<String>>(
        loader: () async => ['alpha', 'beta'],
        builder: (_, data, __) => ListView(
          children: data.map((s) => Text(s)).toList(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('shows error text + Retry when loader throws', (tester) async {
    await tester.pumpWidget(host(
      AsyncView<int>(
        loader: () async => throw StateError('boom'),
        builder: (_, data, __) => Text('$data'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows emptyText when isEmpty is true', (tester) async {
    await tester.pumpWidget(host(
      AsyncView<List<String>>(
        loader: () async => const [],
        isEmpty: (d) => d.isEmpty,
        emptyText: 'nothing to see',
        builder: (_, data, __) => const Text('should not show'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('nothing to see'), findsOneWidget);
    expect(find.text('should not show'), findsNothing);
  });

  testWidgets('controller.refresh re-runs the loader', (tester) async {
    var calls = 0;
    final controller = AsyncViewController();
    await tester.pumpWidget(host(
      AsyncView<int>(
        controller: controller,
        loader: () async => ++calls,
        builder: (_, data, __) => Text('count $data'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('count 1'), findsOneWidget);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('count 2'), findsOneWidget);
  });
}

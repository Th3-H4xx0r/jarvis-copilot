import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jarviscopilot_mobile/main.dart';

void main() {
  testWidgets('JarvisCopilot app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const JarvisCopilotApp());

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

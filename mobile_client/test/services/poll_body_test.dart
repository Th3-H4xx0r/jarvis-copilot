import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/poll_body.dart';

void main() {
  test('foreground poll body sets foreground true', () {
    expect(pollBody(foreground: true), {'foreground': true});
  });
  test('background poll body sets foreground false', () {
    expect(pollBody(foreground: false), {'foreground': false});
  });
}

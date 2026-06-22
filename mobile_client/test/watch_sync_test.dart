import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/services/credentials.dart';
import 'package:jarviscopilot_mobile/services/watch_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jarviscopilot/watch');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('syncs creds + loggedIn=true when paired', () async {
    Credentials.instance
      ..serverUrl = 'https://hermes:8787'
      ..cookie = 'hermes_session=abc'
      ..certFingerprint = 'DEADBEEF';
    await WatchSync.sync();
    expect(calls.single.method, 'syncCredentials');
    final a = calls.single.arguments as Map;
    // Lock the exact arg-key contract the native handler depends on — a key
    // rename typo (e.g. certSha256 → cert_sha256) would silently break the
    // relay, so guard the key SET, not just the values.
    expect(a.keys.toSet(),
        {'serverUrl', 'cookie', 'certSha256', 'cfClientId', 'cfClientSecret', 'loggedIn'});
    expect(a['serverUrl'], 'https://hermes:8787');
    expect(a['cookie'], 'hermes_session=abc');
    expect(a['certSha256'], 'deadbeef'); // lowercased
    expect(a['loggedIn'], true);
  });

  test('loggedIn=false and empty creds when not paired', () async {
    Credentials.instance
      ..serverUrl = null
      ..cookie = null
      ..certFingerprint = null;
    await WatchSync.sync();
    final a = calls.single.arguments as Map;
    expect(a['loggedIn'], false);
    expect(a['serverUrl'], '');
    expect(a['cookie'], '');
    expect(a['certSha256'], '');
  });
}

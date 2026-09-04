import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/chat.dart';
import 'package:jarviscopilot_mobile/services/api_client.dart';

/// A fake [ApiClient] that lets a test script exactly what the streaming
/// POST does, without touching the network (review IMPORTANT — chat.dart's
/// SSE fallback only caught `StateError`; a connect-level failure on the
/// streaming attempt should fall back to the classic two-step flow the same
/// way, but only before any SSE event has reached the caller).
class _FakeApiClient extends ApiClient {
  _FakeApiClient({
    this.postSseOrJsonError,
    this.eventsBeforeError = const [],
    this.startResult,
    this.streamedEvents = const [],
  });

  /// Thrown by [postSseOrJson] AFTER yielding [eventsBeforeError].
  final Object? postSseOrJsonError;
  final List<Map<String, dynamic>> eventsBeforeError;

  /// What the classic two-step `POST /api/chat/start` (no `?stream=1`)
  /// returns, if the fallback is expected to be exercised.
  final Map<String, dynamic>? startResult;
  final List<Map<String, dynamic>> streamedEvents;

  int postSseOrJsonCalls = 0;
  int startMessageCalls = 0;
  int streamEventsCalls = 0;

  @override
  Stream<Map<String, dynamic>> postSseOrJson(
    String path,
    Object body, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async* {
    postSseOrJsonCalls++;
    for (final e in eventsBeforeError) {
      yield e;
    }
    if (postSseOrJsonError != null) {
      throw postSseOrJsonError!;
    }
  }

  @override
  Future<Response<dynamic>> postJson(String path, Object body,
      {Map<String, String>? headers, Duration? timeout}) async {
    startMessageCalls++;
    return Response(
      requestOptions: RequestOptions(path: path),
      data: startResult ?? <String, dynamic>{},
      statusCode: 200,
    );
  }

  @override
  Stream<Map<String, dynamic>> streamSse(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async* {
    streamEventsCalls++;
    for (final e in streamedEvents) {
      yield e;
    }
  }
}

void main() {
  setUp(() {
    // The static feature-detect flag is process-wide (one server per app
    // session) — reset it before every test so tests don't leak into
    // each other.
    ChatApi.streamingStartSupported = null;
  });

  Future<List<Map<String, dynamic>>> drain(ChatApi api) => api
      .sendMessage(sessionId: 's1', text: 'hi')
      .toList();

  group('ChatApi.sendMessage — streaming fallback (review IMPORTANT)', () {
    for (final err in <Object>[
      const SocketException('connection refused'),
      TimeoutException('connect timed out'),
      const HandshakeException('tls handshake failed'),
      const HttpException('bad response'),
    ]) {
      test(
          'falls back to the classic two-step flow on ${err.runtimeType} '
          'before any SSE event is yielded', () async {
        final fake = _FakeApiClient(
          postSseOrJsonError: err,
          startResult: {'stream_id': 'stream-1'},
          streamedEvents: [
            {'event': 'delta', 'text': 'hello'},
            {'event': 'done', 'usage': {}},
          ],
        );
        final api = ChatApi(fake);
        final events = await drain(api);

        expect(fake.postSseOrJsonCalls, 1);
        expect(fake.startMessageCalls, 1,
            reason: 'should have fallen back to POST /api/chat/start');
        expect(fake.streamEventsCalls, 1);
        expect(events.first['event'], 'started');
        expect(events.any((e) => e['event'] == 'delta'), isTrue);
        expect(events.any((e) => e['event'] == 'done'), isTrue);
      });
    }

    test('does NOT fall back / double-submit once an SSE event was already '
        'yielded', () async {
      final fake = _FakeApiClient(
        eventsBeforeError: [
          {'event': 'delta', 'text': 'partial'}
        ],
        postSseOrJsonError: const SocketException('dropped mid-stream'),
      );
      final api = ChatApi(fake);

      await expectLater(
        drain(api),
        throwsA(isA<SocketException>()),
      );
      expect(fake.startMessageCalls, 0,
          reason: 'must not re-submit the turn after streaming had started');
    });

    test('still falls back on the pre-existing StateError case (404/405)',
        () async {
      final fake = _FakeApiClient(
        postSseOrJsonError: StateError('HTTP 404 from /api/chat/start'),
        startResult: {'stream_id': 'stream-1'},
        streamedEvents: [
          {'event': 'done', 'usage': {}},
        ],
      );
      final api = ChatApi(fake);
      final events = await drain(api);
      expect(fake.startMessageCalls, 1);
      expect(events.any((e) => e['event'] == 'done'), isTrue);
    });

    test('a normal SSE stream needs no fallback', () async {
      final fake = _FakeApiClient(eventsBeforeError: [
        {'event': 'delta', 'text': 'hi'},
        {'event': 'done', 'usage': {}},
      ]);
      final api = ChatApi(fake);
      final events = await drain(api);
      expect(fake.startMessageCalls, 0);
      expect(events.length, 2);
    });
  });
}

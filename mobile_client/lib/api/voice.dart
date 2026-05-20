import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

import '../services/api_client.dart' show ApiClient, sha256OfCertPem;
import '../services/credentials.dart';

/// Voice API — both REST (engine list, TTS one-shot) and a separate
/// streaming WS for realtime push-to-talk. The realtime endpoint
/// uses the same /api/voice/s2s/ws path the webui voice page connects to.
class VoiceApi {
  VoiceApi(this.api);
  final ApiClient api;

  Future<Map<String, dynamic>> listEngines() async {
    final resp = await api.get('/api/voice/engines');
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Future<List<int>> tts({required String text, String? voice, String? engine}) async {
    final resp = await api.postJson(
      '/api/voice/synthesize',
      {
        'text': text,
        if (voice != null) 'voice': voice,
        if (engine != null) 'engine': engine,
      },
    );
    final body = resp.data;
    if (body is List<int>) return body;
    if (body is String) return utf8.encode(body);
    return const [];
  }

  Stream<Map<String, dynamic>> qualityTurn({
    required String audioBase64,
    required String sessionId,
    int sampleRate = 16000,
  }) {
    return api.postJsonNdjson('/api/voice/quality-turn', {
      'audio_base64': audioBase64,
      'sample_rate': sampleRate,
      'session_id': sessionId,
    });
  }

  /// Open a streaming voice WS (PTT or realtime). Returns the channel
  /// for the caller to wire up. The native VoicePage owns this.
  Future<IOWebSocketChannel> openRealtime({
    Map<String, String>? params,
  }) async {
    final base = _httpBase(Credentials.instance.serverUrl!);
    final uri = Uri.parse('$base/api/voice/s2s/ws').replace(
      queryParameters: params,
    );
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('serverUrl must be http(s)://... (got "$base")');
    }
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      final expected = Credentials.instance.certFingerprint?.toLowerCase();
      if (expected == null || expected.isEmpty) return false;
      return sha256OfCertPem(cert.pem).toLowerCase() == expected;
    };
    final req = await client.openUrl('GET', uri);
    final key = base64.encode(List<int>.generate(16, (i) => i + 7));
    req.headers
      ..set('Upgrade', 'websocket')
      ..set('Connection', 'Upgrade')
      ..set('Sec-WebSocket-Key', key)
      ..set('Sec-WebSocket-Version', '13')
      ..set('Cookie', Credentials.instance.cookie ?? '');
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.switchingProtocols) {
      throw StateError('Voice WS handshake failed: HTTP ${resp.statusCode}');
    }
    final socket = await resp.detachSocket();
    final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
    return IOWebSocketChannel(ws);
  }

  static String _httpBase(String url) {
    final base = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.startsWith('wss://')) return 'https://${base.substring('wss://'.length)}';
    if (base.startsWith('ws://')) return 'http://${base.substring('ws://'.length)}';
    return base;
  }
}

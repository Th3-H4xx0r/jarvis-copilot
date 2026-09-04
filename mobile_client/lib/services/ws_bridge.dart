import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../skills/common.dart' as common_skills;
import '../skills/registry.dart';
import 'api_client.dart' show ApiClient, sha256OfCertPem;
import 'background_keepalive.dart';
import 'credentials.dart';
import 'invoke_runner.dart';

/// Foreground WebSocket bridge — mirror of [desktop_client/jc_client/
/// service.py:Service] but in Dart. When the app is foregrounded
/// (or, on Android, hosted by the bridge foreground service) the WS
/// stays open and the server can invoke skills directly. When
/// backgrounded on iOS the connection dies; the background path goes
/// through silent APNs → /api/devices/mobile/poll (see PushHandler).
class WsBridge {
  WsBridge({required this.api});

  final ApiClient api;
  InvokeRunner? _runner;

  IOWebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool _stopped = false;
  bool _loopRunning = false; // guards against multiple start() calls
  int _backoffIdx = 0;
  static const _backoff = [1, 2, 4, 8, 16, 32, 60];
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  // Lets pokeReconnect() interrupt the backoff delay so the socket
  // re-opens immediately when the app returns to the foreground.
  Completer<void>? _wake;

  final ValueNotifier<bool> connected = ValueNotifier(false);
  final ValueNotifier<String> lastError = ValueNotifier('');

  void attachRunner(InvokeRunner runner) {
    _runner = runner;
  }

  Future<void> start() async {
    _stopped = false;
    // start() is invoked from main.dart, after pair, and after a
    // skills-disabled toggle in skills_page.dart. Without this guard
    // two _loop coroutines would race to open sockets and fight over
    // _ch / _sub.
    if (_loopRunning) return;
    _loopRunning = true;
    unawaited(_loop().whenComplete(() => _loopRunning = false));
  }

  Future<void> stop() async {
    _stopped = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _ch?.sink.close();
    _sub = null;
    _ch = null;
    connected.value = false;
    // Explicit stop (logout/unpair/skills-disabled toggle): the bridge won't
    // reconnect, so there's nothing left for a background keepalive to
    // preserve — disarm it (Workstream H).
    unawaited(BackgroundKeepalive.instance.syncFromAppState());
  }

  Future<void> _loop() async {
    while (!_stopped) {
      if (!Credentials.instance.isPaired) {
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        await _connectOnce();
        _backoffIdx = 0;
      } catch (e) {
        lastError.value = '$e';
        debugPrint('WS connect failed: $e');
      } finally {
        connected.value = false;
        // Socket dropped (backgrounded/suspended, network blip, server
        // restart, …). Re-evaluate the keepalive: if we're backgrounded and
        // still paired, arm it so the retry below reconnects live instead of
        // falling to the slow silent-push path (Workstream H).
        unawaited(BackgroundKeepalive.instance.syncFromAppState());
      }
      if (_stopped) break;
      final delay = _backoff[_backoffIdx.clamp(0, _backoff.length - 1)];
      _backoffIdx++;
      debugPrint('Reconnecting in ${delay}s …');
      // Interruptible delay: pokeReconnect() (app resume) completes _wake
      // to retry immediately instead of waiting out the backoff.
      _wake = Completer<void>();
      await Future.any([
        Future.delayed(Duration(seconds: delay)),
        _wake!.future,
      ]);
      _wake = null;
    }
  }

  /// Reconnect as soon as possible — resets backoff and wakes the loop out
  /// of its current delay. Call this when the app returns to the foreground
  /// so the live bridge is back up immediately.
  void pokeReconnect() {
    if (_stopped) return;
    _backoffIdx = 0;
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _connectOnce() async {
    final base = _httpBase(Credentials.instance.serverUrl!);
    final httpUrl = '$base/api/devices/bridge/ws';
    final cookie = Credentials.instance.cookie ?? '';

    final socket = await _openSocket(httpUrl, cookie);
    _ch = IOWebSocketChannel(socket);
    connected.value = true;
    lastError.value = '';
    // A live WS means we're paired and reachable — (re-)evaluate whether the
    // background keepalive should be armed (Workstream H). No-op unless the
    // app is currently backgrounded.
    unawaited(BackgroundKeepalive.instance.syncFromAppState());

    final manifest = _currentManifest();
    debugPrint(
      'WS registering ${manifest.length} skills: '
      '${manifest.map((s) => s['name']).join(', ')}',
    );
    _sendRegister(manifest);

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _send({'type': 'ping'});
      } catch (_) {}
    });

    final completer = Completer<void>();
    _sub = _ch!.stream.listen(
      (msg) {
        try {
          final m = json.decode(msg.toString()) as Map<String, dynamic>;
          _handleFrame(m);
        } catch (e) {
          debugPrint('bad WS frame: $e');
        }
      },
      onError: (e) {
        debugPrint('WS error: $e');
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        debugPrint('WS closed');
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    try {
      await completer.future;
    } finally {
      _pingTimer?.cancel();
      _pingTimer = null;
      await _sub?.cancel();
      _sub = null;
      try {
        await _ch?.sink.close();
      } catch (_) {}
      _ch = null;
    }
  }

  Future<WebSocket> _openSocket(String httpUrl, String cookie) async {
    // We use dart:io's WebSocket directly so we can supply a custom
    // HttpClient that enforces cert pinning. HttpClient.openUrl expects
    // http(s):// even when the request upgrades to WebSocket.
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      final expected = Credentials.instance.certFingerprint?.toLowerCase();
      if (expected == null || expected.isEmpty) return false;
      return sha256OfCertPem(cert.pem).toLowerCase() == expected;
    };
    final uri = Uri.parse(httpUrl);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('serverUrl must be http(s)://... (got "$httpUrl")');
    }
    final req = await client.openUrl('GET', uri);
    final key = base64.encode(List<int>.generate(16, (i) => i + 7));
    req.headers
      ..set('Upgrade', 'websocket')
      ..set('Connection', 'Upgrade')
      ..set('Sec-WebSocket-Key', key)
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Protocol', '')
      ..set('Cookie', cookie)
      ..set('User-Agent', 'jc-mobile/0.1');
    // Cloudflare Access service token (no-op when not behind a tunnel).
    Credentials.instance.cfAccessHeaders
        .forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.switchingProtocols) {
      throw StateError('WS handshake failed: HTTP ${resp.statusCode}');
    }
    final socket = await resp.detachSocket();
    return WebSocket.fromUpgradedSocket(socket, serverSide: false);
  }

  void _send(Object frame) {
    final ch = _ch;
    if (ch == null) return;
    try {
      ch.sink.add(json.encode(frame));
    } catch (e) {
      debugPrint('WS send failed: $e');
    }
  }

  void _sendRegister(List<Map<String, dynamic>> manifest) {
    _send({
      'type': 'register',
      'skills': manifest,
      'device': {
        'name': Credentials.instance.deviceName ?? 'mobile',
        'platform': {
          'system': Platform.operatingSystem,
          'release': Platform.operatingSystemVersion,
          'machine': 'mobile',
        },
      },
    });
  }

  Future<void> _handleFrame(Map<String, dynamic> frame) async {
    final t = (frame['type'] ?? '') as String;
    if (t == 'invoke') {
      final callId = (frame['call_id'] ?? '').toString();
      final skill = (frame['skill'] ?? '').toString();
      final args = (frame['args'] is Map)
          ? Map<String, dynamic>.from(frame['args'] as Map)
          : <String, dynamic>{};
      if (callId.isEmpty || skill.isEmpty) {
        debugPrint('invoke missing call_id/skill: $frame');
        return;
      }
      // Run on a microtask so a long-running skill doesn't block the
      // socket receive loop.
      unawaited(_dispatchInvoke(callId, skill, args));
      return;
    }
    if (t == 'ping') {
      _send({'type': 'pong'});
      return;
    }
    if (t == 'hello') {
      final manifest = _currentManifest();
      _sendRegister(manifest);
      return;
    }
    if (t == 'registered') {
      debugPrint('WS server registered ${frame['count'] ?? '?'} skills');
      return;
    }
    if (t == 'pong') {
      return;
    }
    debugPrint('unknown WS frame: $t');
  }

  List<Map<String, dynamic>> _currentManifest() {
    registerCommonSkills(common_skills.everything);
    final manifest = SkillRegistry.instance.manifest(
      disabled: Credentials.instance.skillsDisabled,
    );
    if (manifest.isEmpty) {
      debugPrint(
        'WS skill manifest is empty; disabled=${Credentials.instance.skillsDisabled.toList()} '
        'registered=${SkillRegistry.instance.names()}',
      );
    }
    return manifest;
  }

  Future<void> _dispatchInvoke(
      String callId, String skill, Map<String, dynamic> args) async {
    final runner = _runner;
    if (runner == null) {
      _send({'type': 'error', 'call_id': callId, 'error': 'runner unavailable'});
      return;
    }
    final r = await runner.run(skill, args);
    if (r.error != null) {
      _send({'type': 'error', 'call_id': callId, 'error': r.error});
    } else {
      _send({'type': 'result', 'call_id': callId, 'result': r.result});
    }
  }

  String _httpBase(String url) {
    final base = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.startsWith('wss://')) return 'https://${base.substring('wss://'.length)}';
    if (base.startsWith('ws://')) return 'http://${base.substring('ws://'.length)}';
    return base;
  }
}

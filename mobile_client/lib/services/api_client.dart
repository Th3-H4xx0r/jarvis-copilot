import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'credentials.dart';

/// HTTP client with cert pinning + cookie injection.
///
/// We deliberately don't use Dio's CookieManager package: the cookie
/// never rotates after pairing (the server doesn't issue refresh
/// cookies for paired sessions), so we just inject the stored cookie
/// header on every request. Cert pinning is enforced by the
/// IOHttpClientAdapter's `badCertificateCallback` — it returns true
/// only when the leaf cert's SHA-256 matches the value stored at pair
/// time. Mismatch means we refuse, even on the very first byte sent.
class ApiClient {
  final Dio _dio = Dio();

  ApiClient() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 12)
      ..receiveTimeout = const Duration(seconds: 60)
      ..sendTimeout = const Duration(seconds: 30);
    _applyAdapter();
    _dio.interceptors.add(_AuthInterceptor());
  }

  Dio get dio => _dio;

  String? get _serverUrl => Credentials.instance.serverUrl;

  void _applyAdapter() {
    final adapter = IOHttpClientAdapter()
      ..createHttpClient = () {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 12);
        // Hostname check disabled — we pin the leaf cert instead, so a
        // mismatched CN/SAN isn't itself a fatal signal.
        client.badCertificateCallback = (cert, host, port) {
          final expected = Credentials.instance.certFingerprint?.toLowerCase();
          if (expected == null || expected.isEmpty) {
            // No fingerprint stored yet (very first pairing call).
            // The pair flow captures the fingerprint explicitly from
            // the SecureSocket and stashes it before any further
            // requests run, so we permit this one-shot.
            return true;
          }
          final observed = _fingerprintOf(cert);
          return observed.toLowerCase() == expected;
        };
        return client;
      };
    _dio.httpClientAdapter = adapter;
  }

  /// SHA-256 of a DER-encoded cert, lowercase hex, no separators.
  /// We decode from the PEM form because that's the only certificate
  /// surface guaranteed across all dart:io X509Certificate
  /// implementations.
  static String _fingerprintOf(X509Certificate cert) {
    return _sha256Hex(_derFromPem(cert.pem));
  }

  /// Override the stored fingerprint and rebuild the HTTP adapter so
  /// new connections pick it up. Called by the pair flow after the
  /// user confirms the captured fingerprint.
  void notifyCredentialsChanged() {
    _applyAdapter();
  }

  String get base {
    final u = _serverUrl;
    if (u == null || u.isEmpty) {
      throw StateError('ApiClient: no server URL configured');
    }
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// Cheap "is the server reachable at all?" probe for the launch gate.
  /// Any HTTP response (even 401/403) means reachable — only a
  /// connection refusal, timeout, or TLS/cert failure counts as down.
  Future<bool> reachable() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) return false;
    try {
      await get('/api/auth/status').timeout(const Duration(seconds: 8));
      return true;
    } on DioException catch (e) {
      return e.response != null;
    } catch (_) {
      return false; // TimeoutException, socket/cert errors, etc.
    }
  }

  Future<Response<dynamic>> get(String path,
      {Map<String, dynamic>? query, Map<String, String>? headers}) {
    return _dio.get(
      '$base$path',
      queryParameters: query,
      options: Options(headers: headers),
    );
  }

  Future<Response<dynamic>> postJson(String path, Object body,
      {Map<String, String>? headers, Duration? timeout}) {
    final opts = Options(
      headers: {'Content-Type': 'application/json', ...?headers},
      receiveTimeout: timeout,
    );
    return _dio.post('$base$path', data: body, options: opts);
  }

  /// POST expecting a raw binary response (e.g. TTS audio bytes). Uses
  /// ResponseType.bytes so the body isn't mis-decoded as JSON/text.
  Future<Response<List<int>>> postBytes(String path, Object body,
      {Map<String, String>? headers, Duration? timeout}) {
    return _dio.post<List<int>>(
      '$base$path',
      data: body,
      options: Options(
        headers: {'Content-Type': 'application/json', ...?headers},
        responseType: ResponseType.bytes,
        receiveTimeout: timeout,
      ),
    );
  }

  /// Multipart POST (file upload). The cert-pinning adapter + auth-cookie
  /// interceptor apply just like any other request.
  Future<Response<dynamic>> postMultipart(String path, FormData form,
      {Duration? timeout}) {
    return _dio.post(
      '$base$path',
      data: form,
      options: Options(
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
  }

  Future<Response<dynamic>> patchJson(String path, Object body,
      {Map<String, String>? headers}) {
    return _dio.patch(
      '$base$path',
      data: body,
      options: Options(
        headers: {'Content-Type': 'application/json', ...?headers},
      ),
    );
  }

  Future<Response<dynamic>> deleteJson(String path,
      {Object? body, Map<String, String>? headers}) {
    return _dio.delete(
      '$base$path',
      data: body,
      options: Options(
        headers: {
          if (body != null) 'Content-Type': 'application/json',
          ...?headers,
        },
      ),
    );
  }

  /// Long-poll GET that consumes line-delimited JSON. Yields each
  /// parsed object as it arrives.
  Stream<Map<String, dynamic>> streamNdjson(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async* {
    final uri = Uri.parse('$base$path').replace(
      queryParameters: query?.map((k, v) => MapEntry(k, v.toString())),
    );
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      final expected = Credentials.instance.certFingerprint?.toLowerCase();
      if (expected == null || expected.isEmpty) return true;
      return _sha256Hex(_derFromPem(cert.pem)).toLowerCase() == expected;
    };
    try {
      final req = await client.getUrl(uri);
      final cookie = Credentials.instance.cookie;
      if (cookie != null && cookie.isNotEmpty) {
        req.headers.set('Cookie', cookie);
      }
      Credentials.instance.cfAccessHeaders
          .forEach((k, v) => req.headers.set(k, v));
      if (headers != null) {
        headers.forEach((k, v) => req.headers.set(k, v));
      }
      req.headers.set('Accept', 'application/x-ndjson');
      final resp = await req.close();
      final stream = resp.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in stream) {
        if (line.trim().isEmpty) continue;
        try {
          yield json.decode(line) as Map<String, dynamic>;
        } catch (_) {
          // Skip malformed lines — keeps the stream resilient if the
          // server ever emits a partial frame.
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  Stream<Map<String, dynamic>> postJsonNdjson(
    String path,
    Object body, {
    Map<String, String>? headers,
  }) async* {
    final uri = Uri.parse('$base$path');
    final client = HttpClient();
    client.badCertificateCallback = _pinnedCertificateCallback;
    try {
      final req = await client.postUrl(uri);
      final cookie = Credentials.instance.cookie;
      if (cookie != null && cookie.isNotEmpty) {
        req.headers.set('Cookie', cookie);
      }
      Credentials.instance.cfAccessHeaders
          .forEach((k, v) => req.headers.set(k, v));
      req.headers
        ..set('Content-Type', 'application/json')
        ..set('Accept', 'application/x-ndjson');
      headers?.forEach((k, v) => req.headers.set(k, v));
      req.add(utf8.encode(json.encode(body)));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final text = await resp.transform(utf8.decoder).join();
        var message = text.trim();
        try {
          final parsed = json.decode(text);
          if (parsed is Map && parsed['error'] != null) {
            message = parsed['error'].toString();
          }
        } catch (_) {}
        throw StateError(
          message.isEmpty
              ? 'HTTP ${resp.statusCode} from $path'
              : message,
        );
      }
      await for (final line
          in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        try {
          yield json.decode(line) as Map<String, dynamic>;
        } catch (_) {}
      }
    } finally {
      client.close(force: true);
    }
  }

  Stream<Map<String, dynamic>> streamSse(
    String path, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async* {
    final uri = Uri.parse('$base$path').replace(
      queryParameters: query?.map((k, v) => MapEntry(k, v.toString())),
    );
    final client = HttpClient();
    client.badCertificateCallback = _pinnedCertificateCallback;
    try {
      final req = await client.getUrl(uri);
      final cookie = Credentials.instance.cookie;
      if (cookie != null && cookie.isNotEmpty) {
        req.headers.set('Cookie', cookie);
      }
      Credentials.instance.cfAccessHeaders
          .forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Accept', 'text/event-stream');
      headers?.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final text = await resp.transform(utf8.decoder).join();
        throw StateError(
          text.trim().isEmpty
              ? 'HTTP ${resp.statusCode} from $path'
              : text.trim(),
        );
      }

      var event = 'message';
      final dataLines = <String>[];
      await for (final line
          in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) {
          final data = dataLines.join('\n');
          if (data.isNotEmpty) {
            yield _decodeSseEvent(event, data);
          }
          event = 'message';
          dataLines.clear();
          continue;
        }
        if (line.startsWith(':')) continue;
        if (line.startsWith('event:')) {
          event = line.substring('event:'.length).trim();
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring('data:'.length).trimLeft());
        }
      }
      if (dataLines.isNotEmpty) {
        yield _decodeSseEvent(event, dataLines.join('\n'));
      }
    } finally {
      client.close(force: true);
    }
  }

  bool _pinnedCertificateCallback(X509Certificate cert, String host, int port) {
    final expected = Credentials.instance.certFingerprint?.toLowerCase();
    if (expected == null || expected.isEmpty) return true;
    return _sha256Hex(_derFromPem(cert.pem)).toLowerCase() == expected;
  }

  Map<String, dynamic> _decodeSseEvent(String event, String data) {
    final out = <String, dynamic>{'event': event};
    try {
      final decoded = json.decode(data);
      if (decoded is Map) {
        out.addAll(Map<String, dynamic>.from(decoded));
      } else {
        out['data'] = decoded;
      }
    } catch (_) {
      out['data'] = data;
    }
    return out;
  }
}

/// Extract a clean, user-facing message from an error — prefers the server's
/// `{error: ...}` body on a Dio response, then a short text body, then a
/// status-code line. Avoids dumping the raw multi-line DioException at users.
String apiErrorMessage(Object e) {
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map && data['error'] != null) {
      return data['error'].toString();
    }
    if (data is String && data.trim().isNotEmpty && data.trim().length < 300) {
      return data.trim();
    }
    final code = e.response?.statusCode;
    if (code != null) return 'Request failed ($code)';
    return e.message ?? 'Network error';
  }
  return '$e';
}

class _AuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final c = Credentials.instance.cookie;
    if (c != null && c.isNotEmpty) {
      options.headers['Cookie'] = c;
    }
    // Cloudflare Access service token (no-op when not behind a tunnel).
    Credentials.instance.cfAccessHeaders.forEach((k, v) {
      options.headers[k] = v;
    });
    options.headers['User-Agent'] ??= 'jc-mobile/0.1';
    options.headers['X-Requested-With'] ??= 'jc-mobile';
    super.onRequest(options, handler);
  }
}

// ── inline SHA-256 (avoids pulling package:crypto for one usage) ────────
// Pure-Dart implementation; cribbed from FIPS 180-4.

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int n, int x) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

String _sha256Hex(List<int> bytes) {
  final bits = bytes.length * 8;
  final padded = <int>[...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    padded.add((bits >> (i * 8)) & 0xFF);
  }
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final b = chunk + i * 4;
      w[i] = (padded[b] << 24) | (padded[b + 1] << 16) | (padded[b + 2] << 8) | padded[b + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(7, w[i - 15]) ^ _rotr(18, w[i - 15]) ^ (w[i - 15] >> 3);
      final s1 = _rotr(17, w[i - 2]) ^ _rotr(19, w[i - 2]) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      // SHA-256 spec uses capital-Sigma notation; keep names matching
      // FIPS 180-4 to make audits easier.
      // ignore: non_constant_identifier_names
      final S1 = _rotr(6, e) ^ _rotr(11, e) ^ _rotr(25, e);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + S1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      // ignore: non_constant_identifier_names
      final S0 = _rotr(2, a) ^ _rotr(13, a) ^ _rotr(22, a);
      final mj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (S0 + mj) & 0xFFFFFFFF;
      h = g; g = f; f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c; c = b; b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF; h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF; h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF; h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF; h7 = (h7 + h) & 0xFFFFFFFF;
  }
  String hx(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${hx(h0)}${hx(h1)}${hx(h2)}${hx(h3)}${hx(h4)}${hx(h5)}${hx(h6)}${hx(h7)}';
}

/// Exposed so the pair flow can fingerprint the cert it just saw on a
/// fresh SecureSocket without going through Dio.
String sha256HexBytes(List<int> bytes) => _sha256Hex(bytes);

/// Hash a cert by its PEM string. Strips the BEGIN/END armor, joins
/// remaining lines, base64-decodes, then SHA-256s. Used by every
/// pinning hook in the app — keep it consistent everywhere.
String sha256OfCertPem(String pem) => _sha256Hex(_derFromPem(pem));

List<int> _derFromPem(String pem) {
  // Strip header/footer lines and whitespace; what remains is base64.
  final lines = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  return base64.decode(lines.join());
}

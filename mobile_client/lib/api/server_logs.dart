import '../services/api_client.dart';

/// The log files the server's `GET /api/logs` will serve, mirroring the
/// backend `_LOG_FILE_WHITELIST` in `webui/api/routes.py` (keys: agent /
/// errors / gateway). Any other `file` value returns HTTP 400.
const List<String> serverLogFiles = <String>['agent', 'errors', 'gateway'];

/// Classifies a single log line into a coarse severity bucket, matching the
/// web panel's `_severityForLine` (case-insensitive). Returns one of
/// `'error'`, `'warn'`, or `'info'`.
///
/// ERROR / CRITICAL / Traceback / Exception → `'error'`; WARN / WARNING →
/// `'warn'`; everything else (INFO / DEBUG / plain text) → `'info'`.
String logSeverity(String line) {
  final t = line.toUpperCase();
  if (t.contains('ERROR') ||
      t.contains('CRITICAL') ||
      t.contains('TRACEBACK') ||
      t.contains('EXCEPTION')) {
    return 'error';
  }
  if (t.contains('WARN')) return 'warn';
  return 'info';
}

/// Normalizes the `/api/logs` body into a flat list of log lines.
///
/// The real backend returns `{lines: [...]}` (a list of strings), but we also
/// tolerate a single `{content: "a\nb"}` string, a bare list, or a bare
/// string — splitting on newlines and dropping a trailing empty line.
List<String> parseLogLines(dynamic data) {
  dynamic raw;
  if (data is Map) {
    raw = data['lines'] ?? data['content'];
  } else {
    raw = data;
  }
  if (raw is List) {
    return raw.map((e) => e?.toString() ?? '').toList(growable: false);
  }
  if (raw is String) {
    final parts = raw.split('\n');
    // A trailing newline yields a spurious empty final element; drop it.
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    return List<String>.unmodifiable(parts);
  }
  return const <String>[];
}

/// Reads a bounded tail window of an active-profile server log file from the
/// webui backend (`GET /api/logs`). Parses defensively so a shape change
/// can't crash the screen.
class ServerLogsApi {
  ServerLogsApi(this.api);
  final ApiClient api;

  /// Fetch the last [tail] lines of [file]. Always returns a map exposing a
  /// `List<String> lines`, plus the passthrough metadata the backend sends:
  /// `file`, `tail`, `truncated`, `total_bytes`, `mtime`, `hint`.
  Future<Map<String, dynamic>> tail({
    String file = 'agent',
    int tail = 1000,
  }) async {
    final resp = await api.get(
      '/api/logs',
      query: {'file': file, 'tail': '$tail'},
    );
    final data = resp.data;
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    return <String, dynamic>{
      'file': (map['file'] ?? file).toString(),
      'tail': map['tail'] is int
          ? map['tail']
          : int.tryParse('${map['tail'] ?? tail}') ?? tail,
      'lines': parseLogLines(map.isEmpty ? data : map),
      'truncated': map['truncated'] == true,
      'total_bytes': map['total_bytes'] is num
          ? (map['total_bytes'] as num).toInt()
          : int.tryParse('${map['total_bytes'] ?? 0}') ?? 0,
      'mtime': map['mtime'], // epoch seconds (num) or null
      'hint': (map['hint'] ?? '').toString(),
    };
  }
}

import '../services/api_client.dart';

/// Reads and writes the agent's long-term memory files — MEMORY.md ("My Notes")
/// and USER.md ("User Profile") — via the server's /api/memory endpoints. This
/// is the native equivalent of the webui Memory panel.
///
/// GET  /api/memory        → {memory, user, memory_path, user_path,
///                            memory_mtime, user_mtime}
/// POST /api/memory/write  → {section: 'memory'|'user', content}
class MemoryApi {
  MemoryApi(this.api);
  final ApiClient api;

  /// Returns the whole memory map. Tolerates missing keys (text defaults to '',
  /// mtimes/paths to null) so a partial/older server response still renders.
  Future<Map<String, dynamic>> read() async {
    final resp = await api.get('/api/memory');
    final data = resp.data;
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    return {
      'memory': (map['memory'] ?? '').toString(),
      'user': (map['user'] ?? '').toString(),
      'memory_path': map['memory_path'],
      'user_path': map['user_path'],
      'memory_mtime': map['memory_mtime'],
      'user_mtime': map['user_mtime'],
    };
  }

  /// Overwrites one section's file. [section] is 'memory' or 'user'.
  Future<void> write(String section, String content) async {
    await api.postJson('/api/memory/write', {
      'section': section,
      'content': content,
    });
  }
}

/// Formats a memory file's last-modified time for display. The server sends a
/// unix epoch in SECONDS (e.g. 1718900000.123), but we tolerate anything:
///   - num / numeric string  → absolute local date-time
///   - null / empty / unparseable → '' (caller hides the line)
///   - any other non-empty string → returned as-is (already human-readable)
///
/// Pure + side-effect-free so it can be unit-tested without a server.
String formatMemoryMtime(dynamic mtime) {
  if (mtime == null) return '';

  num? epochSeconds;
  if (mtime is num) {
    epochSeconds = mtime;
  } else if (mtime is String) {
    final s = mtime.trim();
    if (s.isEmpty) return '';
    final parsed = num.tryParse(s);
    if (parsed == null) {
      // Not numeric — assume it's already a formatted timestamp string.
      return s;
    }
    epochSeconds = parsed;
  } else {
    return '';
  }

  if (epochSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(
    (epochSeconds * 1000).round(),
  ).toLocal();
  return _formatDateTime(dt);
}

/// "Jun 21, 2026, 3:07 PM"-style absolute local time, dependency-free.
String _formatDateTime(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final month = months[dt.month - 1];
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  return '$month ${dt.day}, ${dt.year}, $hour12:$minute $ampm';
}

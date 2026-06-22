import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Client for the server's scheduled-tasks ("crons") API. Mirrors the web
/// Tasks panel: list/create/update/delete jobs, run/pause/resume them, and
/// read run history + output.
///
/// The endpoints return slightly different envelope keys than a naive guess
/// (history → `runs`, output → `outputs:[{filename,content}]`), so each method
/// parses defensively and tolerates either a Map wrapper or a bare list.
class CronsApi {
  CronsApi(this.api);
  final ApiClient api;

  /// GET /api/crons → `{jobs: [...]}` (tolerate a bare list).
  Future<List<Map<String, dynamic>>> list() async {
    final resp = await api.get('/api/crons');
    final data = resp.data;
    final raw = data is Map ? (data['jobs'] as List?) : (data as List?);
    return _asMapList(raw);
  }

  /// GET /api/crons/history → `{runs: [...]}`. The server keys the run list as
  /// `runs`; we also tolerate a legacy `entries` key or a bare list.
  Future<List<Map<String, dynamic>>> history(String jobId,
      {int limit = 50}) async {
    final resp = await api.get(
      '/api/crons/history',
      query: {'job_id': jobId, 'limit': '$limit'},
    );
    final data = resp.data;
    final raw = data is Map
        ? ((data['runs'] ?? data['entries']) as List?)
        : (data as List?);
    return _asMapList(raw);
  }

  /// GET /api/crons/output → `{outputs: [{filename, content}]}`. We join each
  /// run's `content` into one string. Tolerates a plain `output` string or a
  /// `lines` list for forward/backward compatibility.
  Future<String> output(String jobId, {int tail = 200}) async {
    final resp = await api.get(
      '/api/crons/output',
      query: {'job_id': jobId, 'tail': '$tail'},
    );
    final data = resp.data;
    if (data is Map) {
      final direct = data['output'];
      if (direct is String && direct.isNotEmpty) return direct;
      final outputs = data['outputs'];
      if (outputs is List && outputs.isNotEmpty) {
        final chunks = <String>[];
        for (final o in outputs) {
          if (o is Map) {
            final c = (o['content'] ?? o['snippet'] ?? '').toString();
            if (c.trim().isEmpty) continue;
            final fn = (o['filename'] ?? '').toString();
            chunks.add(fn.isEmpty ? c : '— $fn —\n$c');
          } else {
            chunks.add(o.toString());
          }
        }
        if (chunks.isNotEmpty) return chunks.join('\n\n');
      }
      final lines = data['lines'];
      if (lines is List) return lines.map((e) => '$e').join('\n');
    } else if (data is String) {
      return data;
    } else if (data is List) {
      return data.map((e) => '$e').join('\n');
    }
    return '';
  }

  /// Fetch the captured output of one specific run (by its history filename).
  Future<String> runOutput(String jobId, String filename) async {
    final resp = await api.get('/api/crons/run',
        query: {'job_id': jobId, 'filename': filename});
    final data = resp.data;
    if (data is Map) {
      final c = data['content'] ?? data['output'];
      if (c != null) return c.toString();
      final lines = data['lines'];
      if (lines is List) return lines.join('\n');
    }
    return '';
  }

  /// POST /api/crons/create.
  Future<void> create(Map<String, dynamic> body) async {
    await api.postJson('/api/crons/create', body);
  }

  /// POST /api/crons/update (body must include `job_id`).
  Future<void> update(Map<String, dynamic> body) async {
    await api.postJson('/api/crons/update', body);
  }

  /// POST /api/crons/delete `{job_id}`.
  Future<void> delete(String jobId) async {
    await api.postJson('/api/crons/delete', {'job_id': jobId});
  }

  /// POST /api/crons/run `{job_id}`.
  Future<void> run(String jobId) async {
    await api.postJson('/api/crons/run', {'job_id': jobId});
  }

  /// POST /api/crons/pause `{job_id}`.
  Future<void> pause(String jobId) async {
    await api.postJson('/api/crons/pause', {'job_id': jobId});
  }

  /// POST /api/crons/resume `{job_id}`.
  Future<void> resume(String jobId) async {
    await api.postJson('/api/crons/resume', {'job_id': jobId});
  }

  static List<Map<String, dynamic>> _asMapList(List? raw) =>
      (raw ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(growable: false);
}

// ── Pure helpers (unit-tested in test/crons_test.dart) ───────────────────

/// Resolve a cron job's id. The server stores it under `id`; the mobile spec
/// and some legacy payloads use `job_id`. Returns '' if neither is present.
String cronJobId(Map<String, dynamic> job) =>
    (job['job_id'] ?? job['id'] ?? '').toString();

/// Resolve a human-readable status for a job. The server returns a structured
/// `state` (`scheduled`/`paused`/`completed`/`error`) plus `enabled` and a
/// `last_status`; the spec also allows a flat `status` string. This mirrors
/// the web panel's `_cronStatusMeta` precedence so labels match parity.
String cronStatusKey(Map<String, dynamic> job) {
  final flat = (job['status'] ?? '').toString().trim().toLowerCase();
  if (flat.isNotEmpty) return flat;
  final state = (job['state'] ?? '').toString().trim().toLowerCase();
  final lastStatus =
      (job['last_status'] ?? '').toString().trim().toLowerCase();
  final enabled = job['enabled'];
  final hasNext = (job['next_run'] ?? job['next_run_at']) != null &&
      (job['next_run'] ?? job['next_run_at']).toString().isNotEmpty;
  if (!hasNext && (state == 'error' || lastStatus == 'error')) {
    return 'needs_attention';
  }
  if (state == 'paused') return 'paused';
  if (enabled == false) return 'off';
  if (lastStatus == 'error' || state == 'error') return 'error';
  if (state == 'running') return 'running';
  if (state.isNotEmpty) return state;
  return 'active';
}

/// Map a status key to a short uppercase badge label.
String cronStatusLabel(String key) {
  switch (key.toLowerCase()) {
    case 'running':
      return 'RUNNING';
    case 'paused':
      return 'PAUSED';
    case 'off':
    case 'disabled':
      return 'OFF';
    case 'error':
      return 'ERROR';
    case 'needs_attention':
    case 'schedule_error':
      return 'NEEDS ATTENTION';
    case 'completed':
      return 'COMPLETED';
    case 'scheduled':
    case 'active':
      return 'ACTIVE';
    default:
      return key.isEmpty ? 'ACTIVE' : key.toUpperCase();
  }
}

/// Badge colour for a status key. running→primaryBlue, paused→muted,
/// error/needs→danger, otherwise success.
Color cronStatusColor(String key) {
  switch (key.toLowerCase()) {
    case 'running':
      return JcTheme.primaryBlue;
    case 'paused':
    case 'off':
    case 'disabled':
    case 'completed':
      return JcTheme.muted;
    case 'error':
    case 'needs_attention':
    case 'schedule_error':
      return JcTheme.danger;
    default:
      return JcTheme.success;
  }
}

/// True if the job is currently paused (drives the Pause/Resume action choice).
bool cronIsPaused(Map<String, dynamic> job) =>
    cronStatusKey(job) == 'paused' ||
    (job['state'] ?? '').toString().trim().toLowerCase() == 'paused';

/// Resolve the human schedule string. The server stores `schedule` as a dict
/// and exposes `schedule_display`; the spec allows a flat `schedule` string.
String cronSchedule(Map<String, dynamic> job) {
  final display = (job['schedule_display'] ?? '').toString().trim();
  if (display.isNotEmpty) return display;
  final sched = job['schedule'];
  if (sched is String && sched.trim().isNotEmpty) return sched.trim();
  if (sched is Map) {
    for (final k in const ['display', 'expression', 'value', 'expr', 'run_at']) {
      final v = (sched[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
  }
  return '';
}

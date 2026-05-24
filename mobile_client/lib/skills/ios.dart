import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'registry.dart';

/// iOS-only skills.
///
/// run_shortcut: invoke a user-created Shortcut by name via the
/// x-callback-url protocol. Returns immediately — Shortcuts has no
/// reliable "did it finish" callback for arbitrary actions, so we
/// surface the launched flag and let the agent ask the user.
///
/// HealthKit: read steps / heart-rate / sleep. Implemented over a
/// MethodChannel ("jarviscopilot/healthkit") that the Swift side
/// wires up in AppDelegate.swift. If the channel is unavailable we
/// fall through to an error so the server can pick another tool.

const MethodChannel _healthkitChannel = MethodChannel('jarviscopilot/healthkit');
const MethodChannel _shortcutsChannel = MethodChannel('jarviscopilot/shortcuts');
const MethodChannel _appChannel = MethodChannel('jarviscopilot/app');
const MethodChannel _smsChannel = MethodChannel('jarviscopilot/sms');

// ── Shortcuts x-callback-url result plumbing ──────────────────────────
// run_shortcut opens `shortcuts://x-callback-url/run-shortcut?...` with an
// `x-success=jarviscopilot://shortcut-result?rid=<id>` callback. When the
// Shortcut finishes, iOS re-opens our app at that URL with the shortcut's
// textual output appended as `result`; AppDelegate forwards it here over
// the `jarviscopilot/shortcuts` channel keyed by `rid`.
final Map<String, Completer<Map<String, dynamic>>> _shortcutWaiters = {};
int _shortcutRidSeq = 0;
bool _shortcutHandlerWired = false;

void _ensureShortcutResultHandler() {
  if (_shortcutHandlerWired) return;
  _shortcutHandlerWired = true;
  _shortcutsChannel.setMethodCallHandler((call) async {
    final args = (call.arguments is Map)
        ? Map<String, dynamic>.from(call.arguments as Map)
        : <String, dynamic>{};
    final rid = (args['rid'] ?? '').toString();
    final waiter = _shortcutWaiters.remove(rid);
    if (waiter == null || waiter.isCompleted) return;
    if (call.method == 'shortcutResult') {
      waiter.complete({'ran': true, 'result': (args['result'] ?? '').toString()});
    } else if (call.method == 'shortcutError') {
      waiter.complete({'ran': false, 'error': (args['error'] ?? 'shortcut failed').toString()});
    }
  });
}

final List<SkillEntry> iosSkills = [
  SkillEntry(
    name: 'open_app',
    platform: 'ios',
    description:
        'Open another iOS app by name (twitter, instagram, slack, …) or by URL scheme. '
        'Limited by iOS sandbox to apps that register a URL scheme.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'app': {'type': 'string'},
        'scheme_url': {'type': 'string'},
      },
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      try {
        final r = await _appChannel.invokeMethod<Map>('open', {
          'app': (args['app'] ?? args['name'] ?? '').toString(),
          'scheme_url': (args['scheme_url'] ?? '').toString(),
        });
        return Map<String, dynamic>.from(r ?? const {});
      } on PlatformException catch (e) {
        return {'launched': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'send_sms',
    platform: 'ios',
    description:
        'Open the iOS Messages composer pre-filled with the recipient and body. '
        'iOS requires the user to tap Send — this is not a silent send.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'number': {'type': 'string'},
        'message': {'type': 'string'},
      },
      'required': ['number', 'message'],
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      try {
        final r = await _smsChannel.invokeMethod<Map>('compose', {
          'number': (args['number'] ?? '').toString(),
          'message': (args['message'] ?? '').toString(),
        });
        return Map<String, dynamic>.from(r ?? const {'shown': true});
      } on PlatformException catch (e) {
        return {'shown': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'run_shortcut',
    platform: 'ios',
    description:
        "Run an iOS Shortcut by name and return its text output. Shortcuts are "
        "the main way to control an iPhone: a Shortcut can toggle settings "
        "(Low Power Mode, Wi-Fi, Focus, brightness, volume), control HomeKit "
        "scenes/devices, play/pause media, get battery/location/clipboard, send "
        "messages, open apps or URLs, run SSH/HTTP requests, and more. Pass the "
        "exact Shortcut name (case-sensitive) and optional text 'input'. Returns "
        "{ran:true, result:<the shortcut's output text>} or {ran:false, error}. "
        "If the Shortcut produces no output you may get an empty result. Use the "
        "'JarvisCopilot Runner' Shortcut (see setup) as a general dispatcher when "
        "no specific Shortcut exists for the task.",
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'Exact Shortcut name as it appears in the Shortcuts app.',
        },
        'input': {
          'type': 'string',
          'description': 'Optional text passed as the Shortcut input.',
        },
        'timeout_seconds': {
          'type': 'integer',
          'minimum': 5,
          'maximum': 300,
          'description': 'How long to wait for the Shortcut to finish (default 90).',
        },
      },
      'required': ['name'],
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final name = (args['name'] ?? '').toString();
      final input = (args['input'] ?? '').toString();
      if (name.isEmpty) throw ArgumentError('name required');
      final timeout = (args['timeout_seconds'] is num)
          ? (args['timeout_seconds'] as num).toInt()
          : 90;

      _ensureShortcutResultHandler();
      final rid = 'sc${_shortcutRidSeq++}_${DateTime.now().millisecondsSinceEpoch}';
      final completer = Completer<Map<String, dynamic>>();
      _shortcutWaiters[rid] = completer;

      // x-callback-url: Shortcuts re-opens us at x-success with the
      // shortcut's output appended as `result` (x-error → errorMessage).
      final uri = Uri(
        scheme: 'shortcuts',
        host: 'x-callback-url',
        path: '/run-shortcut',
        queryParameters: {
          'name': name,
          if (input.isNotEmpty) 'input': 'text',
          if (input.isNotEmpty) 'text': input,
          // rid in the PATH (not a query) so Shortcuts can cleanly append
          // its own `?result=…` / `?errorMessage=…` without a double-query.
          'x-success': 'jarviscopilot://shortcut-result/$rid',
          'x-error': 'jarviscopilot://shortcut-error/$rid',
          'x-cancel': 'jarviscopilot://shortcut-error/$rid',
        },
      );
      final launched = await launchUrl(uri);
      if (!launched) {
        _shortcutWaiters.remove(rid);
        return {'ran': false, 'error': 'Could not open Shortcuts (is it installed?)'};
      }
      try {
        return await completer.future.timeout(Duration(seconds: timeout));
      } on TimeoutException {
        _shortcutWaiters.remove(rid);
        return {
          'ran': true,
          'result': null,
          'note':
              'Launched but no result within ${timeout}s — the Shortcut may still '
              'be running, awaiting input, or produces no output.',
        };
      }
    },
  ),
  SkillEntry(
    name: 'read_healthkit',
    platform: 'ios',
    description: 'Read steps / heart-rate / sleep over the last N days.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'metric': {
          'type': 'string',
          'enum': ['steps', 'heart_rate', 'sleep', 'workouts'],
        },
        'days': {'type': 'integer', 'minimum': 1, 'maximum': 30},
      },
      'required': ['metric'],
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final metric = (args['metric'] ?? '').toString();
      final days =
          (args['days'] is num) ? (args['days'] as num).toInt() : 1;
      try {
        final r = await _healthkitChannel.invokeMethod<Map>(
          'read',
          {'metric': metric, 'days': days},
        );
        return r == null
            ? {'error': 'healthkit returned null'}
            : Map<String, dynamic>.from(r);
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'shortcuts_list',
    platform: 'ios',
    description: 'Return names of installed user Shortcuts (best-effort).',
    inputSchema: {'type': 'object'},
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      try {
        final r = await _shortcutsChannel.invokeMethod<List>('list');
        return {'names': r?.map((e) => e.toString()).toList() ?? const []};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
];

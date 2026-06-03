import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'phone_command.dart';
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

// Cached capabilities manifest from the dispatcher's `capabilities` query, so
// the LLM needn't re-run the visible bounce mid-conversation. Cleared by a
// forced refresh (refresh:true). `_phoneCapsInflight` coalesces concurrent
// discovery so two callers don't both trigger a visible Shortcuts bounce.
Map<String, dynamic>? _phoneCapsCache;
Future<Map<String, dynamic>>? _phoneCapsInflight;

/// Run the dispatcher's `capabilities` query and cache a COPY of a valid result
/// (a copy so a caller mutating the returned map can't corrupt the cache).
Future<Map<String, dynamic>> _fetchPhoneCapabilities() async {
  final res = await _runShortcut('JarvisCopilot Runner',
      input: '{"action":"capabilities"}', timeout: 30);
  if (res['ran'] == false) return res; // could not open Shortcuts
  if (res.containsKey('note')) return res; // timed out
  final parsed = parsePhoneOutput(res['result'] as String?);
  if (parsed['ok'] == true && parsed.containsKey('capabilities')) {
    _phoneCapsCache = Map<String, dynamic>.from(parsed);
  }
  return parsed;
}

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

/// Run a named Shortcut via x-callback-url.
///
/// [awaitResult] true  → include x-success/x-error, wait up to [timeout]s, and
///                       return {ran:true, result:…} (or {ran:false,error}/timeout note).
/// [awaitResult] false → "launch" mode: omit the callbacks so iOS leaves the
///                       user in whatever app the Shortcut opens; return
///                       {ran:true, launched:<bool>} immediately.
Future<Map<String, dynamic>> _runShortcut(
  String name, {
  String input = '',
  int timeout = 90,
  bool awaitResult = true,
}) async {
  _ensureShortcutResultHandler();
  final rid = 'sc${_shortcutRidSeq++}_${DateTime.now().millisecondsSinceEpoch}';

  // rid in the PATH (not a query) so Shortcuts can cleanly append its own
  // `?result=…` / `?errorMessage=…` callback without a double-query.
  final query = <String, String>{
    'name': name,
    if (input.isNotEmpty) 'input': 'text',
    if (input.isNotEmpty) 'text': input,
  };
  Completer<Map<String, dynamic>>? completer;
  if (awaitResult) {
    completer = Completer<Map<String, dynamic>>();
    _shortcutWaiters[rid] = completer;
    query['x-success'] = 'jarviscopilot://shortcut-result/$rid';
    query['x-error'] = 'jarviscopilot://shortcut-error/$rid';
    query['x-cancel'] = 'jarviscopilot://shortcut-error/$rid';
  }

  final uri = Uri(
      scheme: 'shortcuts',
      host: 'x-callback-url',
      path: '/run-shortcut',
      queryParameters: query);
  final launched = await launchUrl(uri);

  if (!awaitResult) {
    return {'ran': launched, 'launched': launched};
  }
  if (!launched) {
    _shortcutWaiters.remove(rid);
    return {'ran': false, 'error': 'Could not open Shortcuts (is it installed?)'};
  }
  try {
    return await completer!.future.timeout(Duration(seconds: timeout));
  } on TimeoutException {
    _shortcutWaiters.remove(rid);
    return {
      'ran': true,
      'result': null,
      'note': 'Launched but no result within ${timeout}s — the Shortcut may '
          'still be running, awaiting input, or produces no output.',
    };
  }
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
      if (name.isEmpty) throw ArgumentError('name required');
      final input = (args['input'] ?? '').toString();
      final timeout = (args['timeout_seconds'] is num)
          ? (args['timeout_seconds'] as num).toInt()
          : 90;
      return _runShortcut(name, input: input, timeout: timeout);
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
  SkillEntry(
    name: 'create_shortcut',
    platform: 'ios',
    description:
        "Create an iOS Shortcut. iOS has NO API to author Shortcuts silently, so "
        "this opens the Shortcuts app: with no args it opens a blank new-shortcut "
        "editor; with import_url (a hosted .shortcut file / iCloud share link) it "
        "opens the import-confirm screen so the user taps Add. To RUN an existing "
        "Shortcut afterwards, use run_shortcut.",
    inputSchema: {
      'type': 'object',
      'properties': {
        'import_url': {
          'type': 'string',
          'description': 'URL of a hosted .shortcut file or iCloud share link to import.',
        },
        'name': {'type': 'string', 'description': 'Suggested name when importing.'},
      },
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final importUrl = (args['import_url'] ?? '').toString();
      final name = (args['name'] ?? '').toString();
      final Uri uri = importUrl.isNotEmpty
          ? Uri(
              scheme: 'shortcuts',
              host: 'x-callback-url',
              path: '/import-shortcut',
              queryParameters: {
                'url': importUrl,
                if (name.isNotEmpty) 'name': name,
              },
            )
          : Uri(scheme: 'shortcuts', host: 'create-shortcut');
      final opened = await launchUrl(uri);
      return {
        'opened': opened,
        'mode': importUrl.isNotEmpty ? 'import' : 'create',
        if (!opened) 'error': 'Could not open Shortcuts (is it installed?)',
      };
    },
  ),
  SkillEntry(
    name: 'phone_control',
    platform: 'ios',
    description: phoneControlDescription,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {'type': 'string'},
        'app': {'type': 'string'},
        'url': {'type': 'string'},
        'setting': {'type': 'string'},
        'value': {},
        'op': {'type': 'string'},
        'what': {'type': 'string'},
        'name': {'type': 'string'},
        'timeout_seconds': {'type': 'integer', 'minimum': 5, 'maximum': 120},
      },
      'required': ['action'],
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final command = buildPhoneCommand(Map<String, dynamic>.from(args));
      final action = command['action'] as String;
      final awaits = phoneActionAwaitsResult(action);
      final timeout = (args['timeout_seconds'] is num)
          ? (args['timeout_seconds'] as num).toInt()
          : 30;
      final res = await _runShortcut(
        'JarvisCopilot Runner',
        input: jsonEncode(command),
        timeout: timeout,
        awaitResult: awaits,
      );
      // Launch-type: pass the raw {ran,launched} through unchanged.
      if (!awaits) return res;
      // Await-type: surface transport failures, else parse the dispatcher's
      // textual output (which lives in res['result']).
      if (res['ran'] == false) return res; // could not open Shortcuts
      if (res.containsKey('note')) return res; // timed out
      return parsePhoneOutput(res['result'] as String?);
    },
  ),
  SkillEntry(
    name: 'phone_capabilities',
    platform: 'ios',
    description:
        'Discover what the "JarvisCopilot Runner" Shortcut on this iPhone can do '
        '(the live verb list for phone_control, including any the user added). '
        'Cached after first call; pass {"refresh": true} to re-query.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'refresh': {'type': 'boolean'},
      },
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final refresh = args['refresh'] == true;
      if (!refresh) {
        if (_phoneCapsCache != null) {
          return {..._phoneCapsCache!, 'cached': true};
        }
        if (_phoneCapsInflight != null) return _phoneCapsInflight!;
      }
      final future = _fetchPhoneCapabilities();
      if (!refresh) _phoneCapsInflight = future;
      try {
        return await future;
      } finally {
        if (identical(_phoneCapsInflight, future)) _phoneCapsInflight = null;
      }
    },
  ),
];

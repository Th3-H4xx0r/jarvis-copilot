import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'contact_lookup.dart';
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
  final params = <String, String>{
    'name': name,
    if (input.isNotEmpty) 'input': 'text',
    if (input.isNotEmpty) 'text': input,
  };
  Completer<Map<String, dynamic>>? completer;
  if (awaitResult) {
    completer = Completer<Map<String, dynamic>>();
    _shortcutWaiters[rid] = completer;
    params['x-success'] = 'jarviscopilot://shortcut-result/$rid';
    params['x-error'] = 'jarviscopilot://shortcut-error/$rid';
    params['x-cancel'] = 'jarviscopilot://shortcut-error/$rid';
  }

  // Build with %20 for spaces (NOT `+`) — see encodeQueryWithPercent20: a
  // Shortcut name like "JC Brightness" must not become "JC+Brightness".
  final uri = Uri.parse(
      'shortcuts://x-callback-url/run-shortcut?${encodeQueryWithPercent20(params)}');
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

/// Open an installed app BY NAME via the "JC Open App" Shortcut (the system
/// "Open App" action — opens any app, not just URL-scheme ones, like Siri).
///
/// Fire-and-forget: "Open App" hands control to the target app, so we must NOT
/// pass an x-success callback (it would yank the user back to JarvisCopilot the
/// instant the target opens). That means we can't observe success — but the
/// system action is reliable for installed apps. Returns whether the Shortcuts
/// URL launched (false only if Shortcuts itself couldn't be opened).
Future<bool> _openAppViaShortcut(String appName) async {
  final res = await _runShortcut('JC Open App', input: appName, awaitResult: false);
  return res['ran'] == true;
}

final List<SkillEntry> iosSkills = [
  SkillEntry(
    name: 'open_app',
    platform: 'ios',
    requiresForeground: true,
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
      final appName = (args['app'] ?? args['name'] ?? '').toString().trim();
      final schemeUrl = (args['scheme_url'] ?? '').toString().trim();
      try {
        final r = await _appChannel.invokeMethod<Map>('open', {
          'app': appName,
          'scheme_url': schemeUrl,
        });
        final res = Map<String, dynamic>.from(r ?? const {});
        if (res['launched'] == true) return res;
        // iOS had no URL scheme for this app. Fall back to the system "Open App"
        // action via the JC Open App Shortcut — it opens ANY installed app by
        // name (what Siri does), not just scheme-registered ones.
        if (appName.isNotEmpty && await _openAppViaShortcut(appName)) {
          return {'launched': true, 'via': 'shortcut', 'app': appName};
        }
        return res;
      } on PlatformException catch (e) {
        if (appName.isNotEmpty && await _openAppViaShortcut(appName)) {
          return {'launched': true, 'via': 'shortcut', 'app': appName};
        }
        return {'launched': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'send_sms',
    platform: 'ios',
    requiresForeground: true,
    description:
        'Send a text via the iOS Messages composer, pre-filled with the recipient '
        'and body. ALWAYS confirm the recipient AND the exact wording with the '
        'user in chat BEFORE invoking this. iOS then also requires the user to tap '
        'Send in the composer — never a silent send — so texting is double-gated.',
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
    requiresForeground: true,
    description:
        "Run an iOS Shortcut by name and return its text output. Shortcuts are "
        "the main way to control an iPhone: a Shortcut can toggle settings "
        "(Low Power Mode, Wi-Fi, Focus, brightness, volume), control HomeKit "
        "scenes/devices, play/pause media, get battery/location/clipboard, send "
        "messages, open apps or URLs, run SSH/HTTP requests, and more. Pass the "
        "exact Shortcut name (case-sensitive) and optional text 'input'. Returns "
        "{ran:true, result:<the shortcut's output text>} or {ran:false, error}. "
        "If the Shortcut produces no output you may get an empty result. To change "
        "iOS-locked settings (brightness, volume, wifi, bluetooth, focus) prefer "
        "the phone_control skill, which drives the per-verb 'JC …' Shortcuts.",
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
    requiresForeground: true,
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
    requiresForeground: true,
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
      // Texting: resolve the recipient NAME to a phone number against the device
      // contacts before handing it to "JC Send Message". Send Message can't
      // convert loose name text to a contact (it errors), but a bare number needs
      // no conversion. Falls back to the raw name on no permission / no match.
      if (command['action'] == 'send_message') {
        final to = (command['to'] ?? command['recipient'] ?? '').toString();
        if (to.isNotEmpty) command['to'] = await resolveRecipient(to);
      }
      // Refuse anything with a native equivalent so we never bounce a Shortcut
      // for open_app/battery/flashlight/alarm/etc. — point JARVIS at the native
      // skill instead.
      final native = nativeRedirectSkill(command);
      if (native != null) {
        return {
          'ok': false,
          'error': "phone_control is only for iOS-locked settings (brightness, "
              "volume, wifi, bluetooth, focus) and open_url. Use the native "
              "'$native' skill for this — it needs no Shortcut and no setup.",
        };
      }
      final target = phoneShortcutFor(command);
      if (target == null) {
        return {
          'ok': false,
          'error': "Unsupported verb '${command['action']}'. phone_control "
              "handles: ${verbShortcutNames.keys.join(', ')}.",
        };
      }
      // Await the x-success callback so iOS bounces BACK to JarvisCopilot after
      // the setting changes (instead of stranding the user in Shortcuts). The
      // verb shortcuts emit no output and finish in ~1s, so the callback fires
      // immediately — the old "hang" was the broken dispatcher never completing,
      // not the await itself.
      final timeout = (args['timeout_seconds'] is num)
          ? (args['timeout_seconds'] as num).toInt()
          : 30;
      final res = await _runShortcut(target.name,
          input: target.input, timeout: timeout, awaitResult: true);
      if (res['ran'] == false) {
        return {
          'ok': false,
          'shortcut': target.name,
          'value': target.input,
          'error': "Could not run '${target.name}'. Make sure that Shortcut is "
              "installed (one-time setup).",
        };
      }
      return {
        'ok': true,
        'shortcut': target.name,
        'value': target.input,
        if (res.containsKey('note')) 'note': res['note'],
      };
    },
  ),
  SkillEntry(
    name: 'phone_capabilities',
    platform: 'ios',
    description:
        'List the iOS-locked settings phone_control can change on this iPhone '
        '(each backed by a one-time "JC <Verb>" Shortcut). Static — no Shortcut '
        'bounce.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      return {
        'ok': true,
        'verbs': verbShortcutNames.keys.toList(),
        'shortcuts': verbShortcutNames,
        'note': 'Each verb runs the matching "JC <Verb>" Shortcut. brightness/'
            'volume take 0.0–1.0; wifi/bluetooth/focus take 1/0; open_url takes '
            'a URL. If a verb errors, that Shortcut is not installed.',
      };
    },
  ),
];

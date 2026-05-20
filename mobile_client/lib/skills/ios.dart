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
    description: 'Run a user-created iOS Shortcut by name.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'input': {'type': 'string'},
      },
      'required': ['name'],
    },
    run: (args) async {
      if (!Platform.isIOS) throw StateError('iOS only');
      final name = (args['name'] ?? '').toString();
      final input = (args['input'] ?? '').toString();
      if (name.isEmpty) throw ArgumentError('name required');
      // Use the documented Shortcuts URL scheme directly.
      final uri = Uri(
        scheme: 'shortcuts',
        host: 'run-shortcut',
        queryParameters: {
          'name': name,
          if (input.isNotEmpty) 'input': input,
        },
      );
      final ok = await launchUrl(uri);
      return {'launched': ok};
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

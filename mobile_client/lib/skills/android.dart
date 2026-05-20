import 'dart:io';

import 'package:flutter/services.dart';

import 'registry.dart';

/// Android-only skills.
///
/// We route through method channels so the heavy permissions
/// (SEND_SMS, NotificationListener, AccessibilityService) live in
/// Kotlin and are gated by their own runtime checks. Each channel is
/// implemented in mobile_client/android/app/src/main/kotlin/.../skills/.

const MethodChannel _smsChannel = MethodChannel('jarviscopilot/sms');
const MethodChannel _notifChannel = MethodChannel('jarviscopilot/notif');
const MethodChannel _a11yChannel = MethodChannel('jarviscopilot/a11y');
const MethodChannel _taskerChannel = MethodChannel('jarviscopilot/tasker');
const MethodChannel _appChannel = MethodChannel('jarviscopilot/app');
const MethodChannel _audioChannel = MethodChannel('jarviscopilot/audio');

final List<SkillEntry> androidSkills = [
  SkillEntry(
    name: 'open_app',
    platform: 'android',
    description:
        'Open an Android app by app name, package name, or URL scheme.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'app': {'type': 'string'},
        'name': {'type': 'string'},
        'package_name': {'type': 'string'},
        'scheme_url': {'type': 'string'},
      },
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _appChannel.invokeMethod<Map>('open', {
          'app': (args['app'] ?? args['name'] ?? '').toString(),
          'package_name': (args['package_name'] ?? '').toString(),
          'scheme_url': (args['scheme_url'] ?? '').toString(),
        });
        return Map<String, dynamic>.from(r ?? const {});
      } on PlatformException catch (e) {
        return {'launched': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'adjust_volume',
    platform: 'android',
    description: 'Raise, lower, mute, or unmute Android media volume.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'mute', 'unmute']
        },
        'steps': {'type': 'integer'},
      },
      'required': ['direction'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _audioChannel.invokeMethod<Map>('adjustVolume', {
          'direction': (args['direction'] ?? '').toString(),
          'steps': args['steps'] ?? 1,
        });
        return Map<String, dynamic>.from(r ?? const {});
      } on PlatformException catch (e) {
        return {'ok': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'set_volume',
    platform: 'android',
    description: 'Set Android media volume to a level from 0 to 100.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'level': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      },
      'required': ['level'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _audioChannel.invokeMethod<Map>('setVolume', {
          'level': args['level'] ?? 50,
        });
        return Map<String, dynamic>.from(r ?? const {});
      } on PlatformException catch (e) {
        return {'ok': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'send_sms',
    platform: 'android',
    requiresOptIn: true,
    description: 'Send an SMS to the given number (Android only).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'number': {'type': 'string'},
        'message': {'type': 'string'},
      },
      'required': ['number', 'message'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _smsChannel.invokeMethod<bool>('send', {
          'number': (args['number'] ?? '').toString(),
          'message': (args['message'] ?? '').toString(),
        });
        return {'sent': r ?? false};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'read_notifications',
    platform: 'android',
    requiresOptIn: true,
    description:
        'List the active system notifications. Requires NotificationListener permission.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _notifChannel.invokeMethod<List>('list');
        return {'notifications': r ?? const []};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'type_text',
    platform: 'android',
    requiresOptIn: true,
    description:
        'Type text into the focused field via AccessibilityService.',
    inputSchema: {
      'type': 'object',
      'properties': {'text': {'type': 'string'}},
      'required': ['text'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _a11yChannel.invokeMethod<bool>('typeText', {
          'text': (args['text'] ?? '').toString(),
        });
        return {'ok': r ?? false};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'tap_at',
    platform: 'android',
    requiresOptIn: true,
    description:
        'Tap at the given screen coordinates via AccessibilityService.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'x': {'type': 'number'},
        'y': {'type': 'number'},
      },
      'required': ['x', 'y'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _a11yChannel.invokeMethod<bool>('tap', {
          'x': (args['x'] as num).toDouble(),
          'y': (args['y'] as num).toDouble(),
        });
        return {'ok': r ?? false};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'tasker_invoke',
    platform: 'android',
    description:
        'Fire a Tasker task by name (requires Tasker external-trigger setting).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'task': {'type': 'string'},
        'parameters': {'type': 'object'},
      },
      'required': ['task'],
    },
    run: (args) async {
      if (!Platform.isAndroid) throw StateError('Android only');
      try {
        final r = await _taskerChannel.invokeMethod<bool>('run', {
          'task': (args['task'] ?? '').toString(),
          'parameters': args['parameters'] ?? const {},
        });
        return {'launched': r ?? false};
      } on PlatformException catch (e) {
        return {'error': e.message ?? e.code};
      }
    },
  ),
];

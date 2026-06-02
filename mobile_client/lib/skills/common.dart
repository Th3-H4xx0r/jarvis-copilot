import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:add_2_calendar/add_2_calendar.dart' as add2cal;
import 'package:battery_plus/battery_plus.dart';
import 'package:device_calendar/device_calendar.dart' as device_calendar;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'dart:typed_data';

import 'registry.dart';
import 'android.dart' as android_skills;
import 'ios.dart' as ios_skills;
import '../services/watch_sync.dart';

/// Returns every Tier-1 skill plus any platform-specific ones for the
/// current OS. The InvokeRunner filters disabled skills before
/// dispatch.
List<SkillEntry> get everything {
  final out = <SkillEntry>[
    ..._common,
  ];
  if (Platform.isIOS) {
    out.addAll(ios_skills.iosSkills);
  } else if (Platform.isAndroid) {
    out.addAll(android_skills.androidSkills);
  }
  return out;
}

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();
bool _notificationsInited = false;

Future<void> _ensureNotifications() async {
  if (_notificationsInited) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await _localNotifications.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
  );
  _notificationsInited = true;
}

/// Shared local-notification helper (also used by the connection monitor).
Future<void> showLocalNotification(String title, String body) async {
  await _ensureNotifications();
  const androidDetails = AndroidNotificationDetails(
    'jc_skill_channel', 'JarvisCopilot',
    importance: Importance.high, priority: Priority.high,
  );
  const iosDetails = DarwinNotificationDetails();
  await _localNotifications.show(
    DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
    title, body,
    const NotificationDetails(android: androidDetails, iOS: iosDetails),
  );
}

/// One audio player reused for agent-played clips (JARVIS voice, etc.).
final AudioPlayer _clipPlayer = AudioPlayer();

/// Lazily init the timezone DB + local zone (needed for scheduled alarms).
bool _tzReady = false;
Future<void> _ensureTz() async {
  if (_tzReady) return;
  tzdata.initializeTimeZones();
  try {
    tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));
  } catch (_) {/* fall back to the default (UTC) if lookup fails */}
  _tzReady = true;
}

final FlutterTts _tts = FlutterTts();
final Battery _battery = Battery();
final ImagePicker _imagePicker = ImagePicker();

/// Channel implemented by both platforms — `TorchBridge` on iOS,
/// `TorchChannel` on Android. Kept here in common.dart so the skill
/// surface stays unified; if a platform doesn't register the channel
/// the invoke surfaces as `MissingPluginException` and the runner
/// reports a graceful error.
const MethodChannel _torchChannel = MethodChannel('jarviscopilot/torch');

final List<SkillEntry> _common = [
  SkillEntry(
    name: 'open_url',
    description: 'Open a URL in the default browser on this device.',
    inputSchema: {
      'type': 'object',
      'properties': {'url': {'type': 'string'}},
      'required': ['url'],
    },
    run: (args) async {
      final url = (args['url'] ?? '').toString();
      if (url.isEmpty) throw ArgumentError('url required');
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return {'launched': ok};
    },
  ),
  SkillEntry(
    name: 'open_app',
    description: 'Open another app by URL scheme (e.g. "twitter://").',
    inputSchema: {
      'type': 'object',
      'properties': {'scheme_url': {'type': 'string'}},
      'required': ['scheme_url'],
    },
    run: (args) async {
      final url = (args['scheme_url'] ?? '').toString();
      if (url.isEmpty) throw ArgumentError('scheme_url required');
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return {'launched': ok};
    },
  ),
  SkillEntry(
    name: 'notify',
    description: 'Show a local notification on this device.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'body': {'type': 'string'},
      },
      'required': ['title'],
    },
    run: (args) async {
      await _ensureNotifications();
      final title = (args['title'] ?? '').toString();
      final body = (args['body'] ?? '').toString();
      const androidDetails = AndroidNotificationDetails(
        'jc_skill_channel',
        'JarvisCopilot',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails();
      await _localNotifications.show(
        DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
      return {'shown': true};
    },
  ),
  SkillEntry(
    name: 'clipboard_read',
    description: 'Read the current clipboard text.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return {'text': data?.text ?? ''};
    },
  ),
  SkillEntry(
    name: 'clipboard_write',
    description: 'Replace the clipboard contents with the given text.',
    inputSchema: {
      'type': 'object',
      'properties': {'text': {'type': 'string'}},
      'required': ['text'],
    },
    run: (args) async {
      final text = (args['text'] ?? '').toString();
      await Clipboard.setData(ClipboardData(text: text));
      return {'wrote': text.length};
    },
  ),
  SkillEntry(
    name: 'share_text',
    description: 'Open the system share sheet with given text.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'subject': {'type': 'string'},
      },
      'required': ['text'],
    },
    run: (args) async {
      final text = (args['text'] ?? '').toString();
      final subject = (args['subject'] ?? '').toString();
      await Share.share(text, subject: subject.isEmpty ? null : subject);
      return {'shared': true};
    },
  ),
  SkillEntry(
    name: 'device_info',
    description: 'Return model, OS, locale info for this device.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      final plugin = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        return {
          'platform': 'ios',
          'model': i.utsname.machine,
          'name': i.name,
          'system': i.systemName,
          'system_version': i.systemVersion,
          'locale': Platform.localeName,
        };
      } else if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        return {
          'platform': 'android',
          'model': a.model,
          'manufacturer': a.manufacturer,
          'system': 'Android',
          'system_version': a.version.release,
          'sdk_int': a.version.sdkInt,
          'locale': Platform.localeName,
        };
      }
      return {'platform': Platform.operatingSystem};
    },
  ),
  SkillEntry(
    name: 'battery_level',
    description: 'Return battery percentage (0-100) and charging state.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      return {
        'level': level,
        'state': state.toString().split('.').last,
      };
    },
  ),
  SkillEntry(
    name: 'vibrate',
    description:
        'Vibrate the device. Pass duration_ms for a single buzz (up to 30s), OR '
        'a pattern of alternating wait/vibrate millisecond steps '
        '(e.g. [0,500,250,500] = buzz 500, pause 250, buzz 500). Optional repeat '
        'loops the buzz/pattern. Use a long duration or a repeated pattern for an '
        'insistent, alarm-style haptic.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'duration_ms': {'type': 'integer', 'minimum': 1, 'maximum': 30000},
        'pattern': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description': 'Alternating wait/vibrate ms; overrides duration_ms.',
        },
        'repeat': {'type': 'integer', 'minimum': 1, 'maximum': 20},
        'target': {
          'type': 'string',
          'enum': ['phone', 'watch', 'both'],
          'description':
              'Where to vibrate (default phone). watch/both pulses the Apple '
              'Watch haptic (iOS, repeat = pulse count).',
        },
      },
    },
    run: (args) async {
      final repeat = (args['repeat'] is num)
          ? (args['repeat'] as num).toInt().clamp(1, 20)
          : 1;
      final target = (args['target'] ?? 'phone').toString();
      if (Platform.isIOS && (target == 'watch' || target == 'both')) {
        await WatchSync.sendHapticToWatch(repeat.clamp(1, 10));
        if (target == 'watch') {
          return {'vibrated': true, 'target': 'watch', 'count': repeat.clamp(1, 10)};
        }
      }
      if (!(await Vibration.hasVibrator())) {
        return {'vibrated': false, 'reason': 'no vibrator'};
      }
      final raw = args['pattern'];
      if (raw is List && raw.isNotEmpty) {
        final pattern = raw
            .map((e) => (e is num ? e.toInt() : 0).clamp(0, 30000))
            .toList();
        final total = pattern.fold<int>(0, (a, b) => a + b);
        for (var i = 0; i < repeat; i++) {
          await Vibration.vibrate(pattern: pattern);
          if (repeat > 1 && i < repeat - 1) {
            await Future.delayed(Duration(milliseconds: total + 100));
          }
        }
        return {'vibrated': true, 'pattern': pattern, 'repeat': repeat};
      }
      final dur = ((args['duration_ms'] is num)
              ? (args['duration_ms'] as num).toInt()
              : 300)
          .clamp(1, 30000);
      for (var i = 0; i < repeat; i++) {
        await Vibration.vibrate(duration: dur);
        if (repeat > 1 && i < repeat - 1) {
          await Future.delayed(Duration(milliseconds: dur + 150));
        }
      }
      return {'vibrated': true, 'duration_ms': dur, 'repeat': repeat};
    },
  ),
  SkillEntry(
    name: 'get_location',
    description: 'Return a one-shot GPS fix (latitude, longitude, accuracy).',
    inputSchema: {'type': 'object'},
    run: (args) async {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('location permission denied');
      }
      // geolocator 11.x exposes `desiredAccuracy`; the `locationSettings`
      // form only landed in 12.x. Stay on the 11.x API while we're pinned
      // to that version (chosen to keep firebase_messaging 14.x happy).
      //
      // Cap the fix attempt and fall back to the last known position so
      // this returns in seconds instead of hanging to the server's 30s
      // invoke timeout when a fresh GPS fix is slow (indoors / cold start).
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 12),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      pos ??= await Geolocator.getLastKnownPosition();
      if (pos == null) {
        throw StateError('no location fix available (try again outdoors)');
      }
      return {
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy_m': pos.accuracy,
        'ts': pos.timestamp.toIso8601String(),
      };
    },
  ),
  SkillEntry(
    name: 'take_photo',
    description: 'Open the camera, return the captured photo as base64.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      final file = await _imagePicker.pickImage(source: ImageSource.camera);
      if (file == null) return {'cancelled': true};
      final bytes = await file.readAsBytes();
      // image_picker returns JPEG on iOS and the platform default on
      // Android (usually JPEG too). We report jpeg honestly; consumers
      // can sniff if they care.
      return {
        'base64': base64.encode(bytes),
        'mime': 'image/jpeg',
        'bytes': bytes.length,
      };
    },
  ),
  SkillEntry(
    name: 'pick_photo',
    description: 'Open the gallery picker, return the chosen photo as base64.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (file == null) return {'cancelled': true};
      final bytes = await file.readAsBytes();
      return {
        'base64': base64.encode(bytes),
        'mime': 'image/jpeg',
        'bytes': bytes.length,
      };
    },
  ),
  SkillEntry(
    name: 'text_to_speech',
    description: 'Speak the given text via the on-device TTS engine.',
    inputSchema: {
      'type': 'object',
      'properties': {'text': {'type': 'string'}, 'voice': {'type': 'string'}},
      'required': ['text'],
    },
    run: (args) async {
      final text = (args['text'] ?? '').toString();
      final voice = (args['voice'] ?? '').toString();
      final locale = (args['locale'] ?? 'en-US').toString();
      if (text.isEmpty) throw ArgumentError('text required');
      if (voice.isNotEmpty) {
        // flutter_tts 4.x requires both name AND locale in the map;
        // passing only `name` crashes on iOS.
        await _tts.setVoice({'name': voice, 'locale': locale});
      }
      final r = await _tts.speak(text);
      return {'ok': r == 1};
    },
  ),
  SkillEntry(
    name: 'play_audio',
    description:
        'Play an audio clip through this device\'s speaker — e.g. a '
        'server-generated JARVIS-voice TTS clip. Pass audio_base64 (raw bytes; '
        'mp3/wav/m4a/etc.) OR a url. Prefer this over text_to_speech when you '
        'want the real JARVIS voice instead of the phone\'s built-in synthesizer.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'audio_base64': {'type': 'string'},
        'url': {'type': 'string'},
        'volume': {'type': 'number', 'minimum': 0, 'maximum': 1},
        'target': {
          'type': 'string',
          'enum': ['phone', 'watch', 'both'],
          'description':
              'Where to play (default phone). watch/both plays on the Apple '
              'Watch (iOS; needs audio_base64, not url).',
        },
      },
    },
    run: (args) async {
      final b64 = (args['audio_base64'] ?? '').toString();
      final url = (args['url'] ?? '').toString();
      final vol = (args['volume'] is num)
          ? (args['volume'] as num).toDouble().clamp(0.0, 1.0)
          : 1.0;
      final target = (args['target'] ?? 'phone').toString();
      if (Platform.isIOS && (target == 'watch' || target == 'both') && b64.isNotEmpty) {
        await WatchSync.sendClipToWatch(
            b64.contains(',') ? b64.split(',').last : b64);
        if (target == 'watch') return {'played': true, 'target': 'watch'};
      }
      try {
        await _clipPlayer.setVolume(vol);
        if (b64.isNotEmpty) {
          // iOS: BytesSource is unreliable → write a temp file and play that.
          final bytes =
              base64Decode(b64.contains(',') ? b64.split(',').last : b64);
          final dir = await getTemporaryDirectory();
          final f = File(
              '${dir.path}/jc_clip_${DateTime.now().millisecondsSinceEpoch}.audio');
          await f.writeAsBytes(bytes, flush: true);
          await _clipPlayer.play(DeviceFileSource(f.path));
          return {'played': true, 'bytes': bytes.length};
        }
        if (url.isNotEmpty) {
          await _clipPlayer.play(UrlSource(url));
          return {'played': true, 'url': url};
        }
        return {'played': false, 'error': 'audio_base64 or url required'};
      } catch (e) {
        return {'played': false, 'error': e.toString()};
      }
    },
  ),
  SkillEntry(
    name: 'set_alarm',
    description:
        'Schedule an on-device alarm: a local notification with an alarm sound + '
        'vibration that fires at the given time even if the app is closed. Give '
        'the time as 24h hour (+minute) for the next occurrence, OR in_minutes '
        'from now. Optional label. Note: it respects the OS Silent / '
        'Do-Not-Disturb settings (iOS has no public API for a true Clock alarm).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'hour': {'type': 'integer', 'minimum': 0, 'maximum': 23},
        'minute': {'type': 'integer', 'minimum': 0, 'maximum': 59},
        'in_minutes': {'type': 'integer', 'minimum': 1, 'maximum': 1440},
        'label': {'type': 'string'},
      },
    },
    run: (args) async {
      await _ensureTz();
      await _ensureNotifications();
      final label = (args['label'] ?? 'Alarm').toString();
      final now = tz.TZDateTime.now(tz.local);
      tz.TZDateTime when;
      if (args['in_minutes'] is num) {
        when = now.add(Duration(minutes: (args['in_minutes'] as num).toInt()));
      } else if (args['hour'] is num) {
        final h = (args['hour'] as num).toInt();
        final m = (args['minute'] is num) ? (args['minute'] as num).toInt() : 0;
        when = tz.TZDateTime(tz.local, now.year, now.month, now.day, h, m);
        if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
      } else {
        return {'scheduled': false, 'error': 'hour or in_minutes required'};
      }
      final id = when.millisecondsSinceEpoch.remainder(1 << 31);
      final androidDetails = AndroidNotificationDetails(
        'jc_alarm_channel',
        'JarvisCopilot Alarms',
        channelDescription: 'Scheduled alarms',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        playSound: true,
        enableVibration: true,
        vibrationPattern:
            Int64List.fromList(const [0, 600, 300, 600, 300, 600]),
      );
      const iosDetails = DarwinNotificationDetails(
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      );
      await _localNotifications.zonedSchedule(
        id,
        label,
        'JARVIS alarm',
        when,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      return {'scheduled': true, 'at': when.toIso8601String(), 'id': id};
    },
  ),
  SkillEntry(
    name: 'flashlight_on',
    description: 'Turn on the device flashlight / torch.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      try {
        final r = await _torchChannel.invokeMethod<bool>('on');
        return {'on': r ?? true};
      } on PlatformException catch (e) {
        return {'on': false, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'flashlight_off',
    description: 'Turn off the device flashlight / torch.',
    inputSchema: {'type': 'object'},
    run: (args) async {
      try {
        final r = await _torchChannel.invokeMethod<bool>('off');
        return {'on': r ?? false};
      } on PlatformException catch (e) {
        return {'on': true, 'error': e.message ?? e.code};
      }
    },
  ),
  SkillEntry(
    name: 'make_call',
    description: 'Open the system dialer with the given phone number.',
    inputSchema: {
      'type': 'object',
      'properties': {'number': {'type': 'string'}},
      'required': ['number'],
    },
    run: (args) async {
      final num = (args['number'] ?? '').toString();
      if (num.isEmpty) throw ArgumentError('number required');
      final ok = await launchUrl(Uri.parse('tel:$num'));
      return {'launched': ok};
    },
  ),
  SkillEntry(
    name: 'record_audio',
    description:
        'Record a short audio clip from the mic and return it as base64. '
        'Caller specifies duration in seconds (default 5, max 60).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'duration_s': {'type': 'integer', 'minimum': 1, 'maximum': 60},
      },
    },
    run: (args) async {
      final seconds = (args['duration_s'] is num)
          ? (args['duration_s'] as num).toInt().clamp(1, 60)
          : 5;
      final recorder = AudioRecorder();
      try {
        if (!await recorder.hasPermission()) {
          return {'recorded': false, 'error': 'mic permission denied'};
        }
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/jc-rec-${DateTime.now().millisecondsSinceEpoch}.m4a';
        await recorder.start(const RecordConfig(), path: path);
        await Future<void>.delayed(Duration(seconds: seconds));
        final file = await recorder.stop();
        if (file == null) {
          return {'recorded': false, 'error': 'recorder returned no file'};
        }
        final bytes = await File(file).readAsBytes();
        return {
          'recorded': true,
          'base64': base64.encode(bytes),
          'mime': 'audio/mp4',
          'bytes': bytes.length,
          'duration_s': seconds,
        };
      } finally {
        await recorder.dispose();
      }
    },
  ),
  SkillEntry(
    name: 'read_contacts',
    description:
        'Search the device contacts by name or phone-number substring. '
        'Returns up to 20 matches. Requires contacts permission.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
      },
    },
    run: (args) async {
      final query = (args['query'] ?? '').toString().trim().toLowerCase();
      final limit = (args['limit'] is num) ? (args['limit'] as num).toInt() : 20;
      final ok = await FlutterContacts.requestPermission(readonly: true);
      if (!ok) return {'error': 'contacts permission denied'};
      final all = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      final matches = query.isEmpty
          ? all
          : all.where((c) {
              if (c.displayName.toLowerCase().contains(query)) return true;
              for (final p in c.phones) {
                final normalised = p.number.replaceAll(RegExp(r'[^0-9+]'), '');
                if (normalised.contains(query)) return true;
              }
              return false;
            }).toList();
      final out = matches.take(limit).map((c) => {
            'display_name': c.displayName,
            'phones': c.phones.map((p) => p.number).toList(),
            'emails': c.emails.map((e) => e.address).toList(),
          }).toList();
      return {'contacts': out, 'total': matches.length};
    },
  ),
  SkillEntry(
    name: 'add_calendar_event',
    description:
        'Open the system "add event" sheet pre-filled with title / start / end. '
        'User confirms with Save — this is not a silent insert.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'description': {'type': 'string'},
        'location': {'type': 'string'},
        'start_iso': {'type': 'string'},
        'end_iso': {'type': 'string'},
        'all_day': {'type': 'boolean'},
      },
      'required': ['title', 'start_iso', 'end_iso'],
    },
    run: (args) async {
      final start = DateTime.parse((args['start_iso'] ?? '').toString());
      final end = DateTime.parse((args['end_iso'] ?? '').toString());
      final event = add2cal.Event(
        title: (args['title'] ?? '').toString(),
        description: (args['description'] ?? '').toString(),
        location: (args['location'] ?? '').toString(),
        startDate: start,
        endDate: end,
        allDay: args['all_day'] == true,
      );
      final ok = await add2cal.Add2Calendar.addEvent2Cal(event);
      return {'opened': ok};
    },
  ),
  SkillEntry(
    name: 'list_calendar_events',
    description:
        'List calendar events between two ISO timestamps across all visible calendars. '
        'Requires calendar read permission.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'start_iso': {'type': 'string'},
        'end_iso': {'type': 'string'},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      },
      'required': ['start_iso', 'end_iso'],
    },
    run: (args) async {
      final start = DateTime.parse((args['start_iso'] ?? '').toString());
      final end = DateTime.parse((args['end_iso'] ?? '').toString());
      final limit = (args['limit'] is num) ? (args['limit'] as num).toInt() : 50;
      final plugin = device_calendar.DeviceCalendarPlugin();
      final permResult = await plugin.requestPermissions();
      if (!(permResult.data ?? false)) {
        return {'error': 'calendar permission denied'};
      }
      final calsResult = await plugin.retrieveCalendars();
      final cals = calsResult.data ?? [];
      final out = <Map<String, dynamic>>[];
      for (final cal in cals) {
        if (cal.id == null) continue;
        final eventsResult = await plugin.retrieveEvents(
          cal.id,
          device_calendar.RetrieveEventsParams(startDate: start, endDate: end),
        );
        for (final ev in eventsResult.data ?? <device_calendar.Event>[]) {
          out.add({
            'title': ev.title ?? '',
            'description': ev.description ?? '',
            'location': ev.location ?? '',
            'start_iso': ev.start?.toIso8601String(),
            'end_iso': ev.end?.toIso8601String(),
            'all_day': ev.allDay ?? false,
            'calendar': cal.name ?? '',
          });
          if (out.length >= limit) break;
        }
        if (out.length >= limit) break;
      }
      return {'events': out, 'count': out.length};
    },
  ),
];

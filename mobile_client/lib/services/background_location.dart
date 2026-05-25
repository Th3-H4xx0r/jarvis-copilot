import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';
import 'credentials.dart';

/// Opt-in background location history + connection keep-alive.
///
/// iOS suspends apps in the background — *except* when they're actively
/// using location (the one privileged background mode). So when enabled we
/// run a continuous location stream with `allowBackgroundLocationUpdates`,
/// which (a) keeps the app process alive in the background, so the device
/// bridge socket stays connected and server skills stop timing out, and
/// (b) lets us push a fix to the server every ~10 min / on movement for
/// the history the agent can query later.
///
/// Costs: "Always" location permission, the iOS location indicator, and
/// extra battery. After a force-quit iOS only revives the app on a
/// significant location change (not guaranteed). Off by default.
class BackgroundLocation {
  BackgroundLocation({required this.api});

  final ApiClient api;
  final ValueNotifier<bool> enabled = ValueNotifier(false);

  // Native side runs significant-location-change monitoring that survives
  // a force-quit (iOS relaunches the app on movement and it pushes the fix
  // natively). Dart hands it the server URL + cookie + cert pin.
  static const MethodChannel _native = MethodChannel('jarviscopilot/location');

  StreamSubscription<Position>? _sub;
  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  Position? _lastReported;

  static const Duration _minInterval = Duration(minutes: 10);
  static const double _minMeters = 75;

  /// Toggle tracking. Returns false if location permission was refused
  /// (the caller should point the user at Settings).
  Future<bool> setEnabled(bool on) async {
    if (!on) {
      enabled.value = false;
      await _sub?.cancel();
      _sub = null;
      await _setNativeTracking(false);
      return true;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    // 1) "When In Use" prompt (iOS won't show "Always" on the first ask).
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    // 2) Escalate to "Always" so background tracking actually works — on
    //    iOS this triggers the "Change to Always Allow" system prompt.
    if (perm == LocationPermission.whileInUse) {
      // A beat lets the first dialog fully dismiss before the second.
      await Future.delayed(const Duration(milliseconds: 400));
      perm = await Geolocator.requestPermission();
    }
    enabled.value = true;
    // Native SLC = the force-quit-surviving background mechanism (like
    // Life360). The Dart stream below adds finer updates while alive.
    await _setNativeTracking(true);
    await _startStream();
    unawaited(_reportOnce()); // seed history immediately
    return true;
  }

  /// Native background-location diagnostics for the Settings screen:
  /// {tracking, lastSlc (epoch s), lastPush (epoch s), lastPushStatus}.
  Future<Map<String, dynamic>> diag() async {
    try {
      final r = await _native.invokeMethod('getDiag');
      return r is Map ? Map<String, dynamic>.from(r) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _setNativeTracking(bool on) async {
    try {
      if (on) {
        await _native.invokeMethod('setTracking', {
          'enabled': true,
          'serverUrl': Credentials.instance.serverUrl ?? '',
          'cookie': Credentials.instance.cookie ?? '',
          'certSha256': Credentials.instance.certFingerprint ?? '',
        });
      } else {
        await _native.invokeMethod('setTracking', {'enabled': false});
      }
    } catch (_) {
      // Channel not available (e.g. Android / not wired) — the Dart
      // stream still covers the foreground/alive case.
    }
  }

  Future<void> _startStream() async {
    await _sub?.cancel();
    final LocationSettings settings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 50,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
            activityType: ActivityType.other,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 50,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'JarvisCopilot',
              notificationText: 'Sharing location with your assistant',
              enableWakeLock: true,
            ),
          );
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (e) => debugPrint('[loc] stream error: $e'));
  }

  void _onPosition(Position pos) {
    final now = DateTime.now();
    final movedFar = _lastReported == null ||
        Geolocator.distanceBetween(
              _lastReported!.latitude,
              _lastReported!.longitude,
              pos.latitude,
              pos.longitude,
            ) >=
            _minMeters;
    if (now.difference(_lastReport) >= _minInterval || movedFar) {
      _report(pos);
    }
  }

  Future<void> _reportOnce() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 12),
      );
      _report(pos);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _report(last);
    }
  }

  Future<void> _report(Position pos) async {
    _lastReport = DateTime.now();
    _lastReported = pos;
    try {
      await api.postJson('/api/devices/mobile/location', {
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'ts': pos.timestamp.millisecondsSinceEpoch / 1000.0,
      });
      debugPrint('[loc] reported ${pos.latitude},${pos.longitude}');
    } catch (e) {
      debugPrint('[loc] report failed: $e');
    }
  }
}

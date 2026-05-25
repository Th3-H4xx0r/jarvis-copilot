import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';

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
      return true;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    // whileInUse is enough to begin; true background needs "Always", which
    // iOS escalates to on its own after the app has used location in the
    // background a few times (or the user can set it in Settings).
    enabled.value = true;
    await _startStream();
    unawaited(_reportOnce()); // seed history immediately
    return true;
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

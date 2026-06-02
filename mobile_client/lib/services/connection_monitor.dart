import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skills/common.dart' show showLocalNotification;

/// Watches the bridge connection and posts a local notification when the link
/// to the JARVIS server drops, and again when it comes back online.
///
/// Debounced (4s) so brief reconnect flaps don't spam, and the very first
/// "settle" after launch is silent (we don't announce the initial connect).
class ConnectionMonitor {
  ConnectionMonitor(this._connected);

  final ValueNotifier<bool> _connected;
  bool? _last; // last *notified* state; null until the first settle
  Timer? _debounce;

  void start() => _connected.addListener(_onChange);

  void dispose() {
    _connected.removeListener(_onChange);
    _debounce?.cancel();
  }

  void _onChange() {
    final target = _connected.value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 4), () {
      if (_connected.value != target) return; // flapped back — ignore
      if (_last == null) {
        _last = target; // first settle after launch: establish baseline silently
        return;
      }
      if (target == _last) return;
      _last = target;
      if (target) {
        showLocalNotification('JARVIS reconnected', 'Back online with your server.');
      } else {
        showLocalNotification('JARVIS disconnected', 'Lost connection to your server.');
      }
    });
  }
}

import 'dart:io';

import 'package:flutter/services.dart';

class AndroidAccessibility {
  AndroidAccessibility._();

  static const _channel = MethodChannel('jarviscopilot/a11y');

  static Future<bool> isEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

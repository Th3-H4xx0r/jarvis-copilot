/// Body for POST /api/devices/mobile/poll. The server uses `foreground` to
/// decide whether to hand out foreground-required invokes (true) or withhold
/// them so the background isolate never runs a foreground action headless
/// (false). See the notification-tap bridge spec.
Map<String, dynamic> pollBody({required bool foreground}) =>
    {'foreground': foreground};

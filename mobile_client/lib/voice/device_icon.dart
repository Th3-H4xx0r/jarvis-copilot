/// Map a server device record (from `/api/devices`) to a normalized icon kind
/// for the Live Activity devices strip (rendered by `jcDeviceSymbol` natively).
///
/// The record's authoritative field is `kind` ∈ {browser, desktop, mobile-ios,
/// mobile-android}; we refine it with the free-text `name` + `user_agent` to
/// pick the most recognizable PHYSICAL-device icon — e.g. a browser whose UA
/// says Macintosh shows a laptop, not a generic globe. (The webui's "Chrome ·
/// macOS" label is display-only and never reaches the client, so we must derive
/// from `kind`/`name`/`user_agent`.)
///
/// Returns one of: watch, tablet, phone, laptop, desktop, web.
String deviceIconKind(Map<String, dynamic> d) {
  final kind = (d['kind'] ?? '').toString().toLowerCase();
  final s = '${d['name'] ?? ''} ${d['user_agent'] ?? ''}'.toLowerCase();
  bool has(List<String> tokens) => tokens.any(s.contains);

  if (has(['watch'])) return 'watch';
  if (has(['ipad', 'tablet'])) return 'tablet';
  if (kind == 'mobile-ios' ||
      kind == 'mobile-android' ||
      has(['iphone', 'android'])) {
    return 'phone';
  }
  if (has(['macbook', 'laptop'])) return 'laptop';
  if (has(['imac', 'mac mini', 'mac pro', 'mac studio'])) return 'desktop';
  if (has(['macintosh', 'mac os', 'macos'])) return 'laptop';
  if (has(['windows', 'linux', 'desktop'])) return 'desktop';
  if (kind == 'browser') return 'web';
  return 'desktop';
}

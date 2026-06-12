/// Cadence decisions for the Live Activity coordinator. Pure so they're
/// unit-testable (same idiom as `shouldDeferToForeground` / `pollBody`).
///
/// The fleet/usage poll is the app's single biggest always-on default drain
/// (two HTTP calls every 5s started at launch even with zero sessions). We keep
/// the fast 5s cadence ONLY when there's a live reason to refresh; otherwise we
/// drop to a 60s discovery cadence and let the server's APNs push-to-update keep
/// a backgrounded activity fresh.
const Duration laFastInterval = Duration(seconds: 5);
const Duration laSlowInterval = Duration(seconds: 60);
const Duration laUsageMinInterval = Duration(seconds: 60);

Duration laPollInterval({
  required bool voiceActive,
  required bool codingVisible,
  required int sessionTotal,
}) =>
    (voiceActive || codingVisible || sessionTotal > 0) ? laFastInterval : laSlowInterval;

/// `getUsage()` returns slow-moving quota — it does not need the 5s cadence.
bool shouldFetchUsage({
  required DateTime now,
  required DateTime lastUsageFetch,
}) =>
    now.difference(lastUsageFetch) >= laUsageMinInterval;

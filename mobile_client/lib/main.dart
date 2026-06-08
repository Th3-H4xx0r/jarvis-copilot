import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/coding_sessions.dart';
import 'live_activity/live_activity_coordinator.dart';
import 'nav.dart';
import 'pages/pair_page.dart';
import 'services/api_client.dart';
import 'services/app_lifecycle.dart';
import 'services/background_location.dart';
import 'services/credentials.dart';
import 'services/invoke_runner.dart';
import 'services/pending_actions.dart';
import 'services/connection_monitor.dart';
import 'services/push_handler.dart';
import 'services/watch_sync.dart';
import 'services/ws_bridge.dart';
import 'skills/registry.dart';
import 'skills/common.dart' as common_skills;
import 'theme.dart';
import 'voice/voice_controller.dart';
import 'voice/wake_service.dart';

/// Top-level service handles wired by [main]. The Service binds Flutter
/// to the running platform; we keep these as singletons because the WS
/// bridge and skill runner share state across routes.
late final ApiClient api;
late final WsBridge ws;
late final InvokeRunner runner;
late final PushHandler push;
late final WakeService wake;
late final BackgroundLocation location;
late final ConnectionMonitor connectionMonitor;
/// Single owner of the iOS Live Activity (voice + coding fleet). Also reachable
/// via `LiveActivityCoordinator.instance` from VoiceController.
late final LiveActivityCoordinator liveActivityCoordinator;

/// The ONE voice session for the whole app. VoicePage references this singleton
/// instead of creating its own, so there can only ever be a single live session
/// — even if a VoicePage gets rebuilt — which keeps the Live Activity / orb
/// state from ever showing two conflicting sessions ("idle" on top, "listening"
/// underneath). Lazily built on first use so the audio session isn't configured
/// until voice is actually opened.
VoiceController? _voiceController;
VoiceController get voiceController => _voiceController ??= VoiceController(api);

/// Latched request to "open the Voice tab and start realtime" — fired by
/// the Siri App Intent and the wake word. NavShell switches to the Voice
/// tab; VoicePage starts a turn and clears it. It's a *latch* (not a
/// one-shot event) so it survives cold launch, where the intent fires
/// before NavShell/VoicePage have mounted to hear it.
final ValueNotifier<bool> voiceLaunchRequested = ValueNotifier<bool>(false);

void requestVoiceLaunch() {
  // Re-arm even if a stale `true` is sitting there, so the listeners
  // (and the on-mount checks) reliably fire.
  voiceLaunchRequested.value = false;
  voiceLaunchRequested.value = true;
}

/// Pull the native "pending voice launch" flag (an atomic read+clear on the
/// native side) and, if set, open Voice + start a turn. Retries briefly: on a
/// COLD launch this can run before the native handler is registered (which
/// surfaces as [MissingPluginException]), so we wait and try again until we get
/// a definitive answer. This is the authoritative consume — the native
/// `startVoice` nudge alone is unreliable on cold launch (it can fire before
/// Dart's handler exists), which is why a tapped widget/Control could open the
/// app without reaching the Voice screen.
Future<void> _pullPendingVoice(MethodChannel channel) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    try {
      final pending = await channel.invokeMethod<bool>('consumePendingVoice');
      if (pending == true) requestVoiceLaunch();
      return; // got a definitive answer (true or false)
    } on MissingPluginException {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } catch (_) {
      return;
    }
  }
}

/// Run foreground-required actions that were deferred while the app was
/// backgrounded (a tapped "tap to run" notification, or a manual reopen,
/// foregrounds the app and lands here). The runner now executes them directly
/// because [AppLifecycle.isForeground] is true — no re-defer loop.
Future<void> _runPendingForegroundActions() async {
  if (PendingActions.instance.isEmpty) return;
  for (final a in PendingActions.instance.drainFresh()) {
    await runner.run(a.skill, a.args);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait — the dark, content-heavy layouts don't benefit
  // from landscape, and avoiding rotation simplifies the orb visualizer.
  await SystemChrome.setPreferredOrientations(
    const [DeviceOrientation.portraitUp],
  );

  // Try to bring up Firebase early — needed for FCM/APNs token registration.
  // We tolerate failure (e.g. missing GoogleService-Info.plist on a dev
  // build) and continue without push; the app stays usable in foreground.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase init failed: $e — continuing without push');
  }

  await Credentials.instance.load();

  registerCommonSkills(common_skills.everything);

  api = ApiClient();
  ws = WsBridge(api: api);
  runner = InvokeRunner(api: api, ws: ws);
  push = PushHandler(api: api, runner: runner);

  wake = WakeService(onWake: requestVoiceLaunch)..init();
  location = BackgroundLocation(api: api);
  // Resume tracking across app restarts if the user left it on.
  if (Credentials.instance.trackLocation) {
    unawaited(location.setEnabled(true));
  }

  ws.attachRunner(runner);
  unawaited(ws.start());
  unawaited(push.start());

  // Notify the user when the bridge drops / restores its server connection.
  connectionMonitor = ConnectionMonitor(ws.connected)..start();

  // Single Live Activity owner. start() begins the app-wide coding-sessions
  // poll (gated by the settings toggle) so the Lock Screen / Dynamic Island
  // auto-shows live sessions without the user opening Voice first.
  liveActivityCoordinator = LiveActivityCoordinator(CodingSessionsApi(api))
    ..start();

  // Siri intent / Control Center / Lock-screen widget → native sets a pending
  // flag and nudges us via `startVoice`. We PULL the flag from native (on the
  // nudge AND once at startup) rather than trusting the nudge alone, so a cold
  // launch that races ahead of this handler still reaches the Voice screen.
  const intentsChannel = MethodChannel('jarviscopilot/intents');
  intentsChannel.setMethodCallHandler((call) async {
    // Fire the pull as a SEPARATE top-level future — do NOT await it inside the
    // handler. Making an outgoing call (consumePendingVoice) on the same channel
    // while handling an incoming one (startVoice) can stall on a warm resume,
    // which is why cold launch (top-level startup pull) worked but a
    // backgrounded app brought forward by the widget/Control didn't.
    if (call.method == 'startVoice') unawaited(_pullPendingVoice(intentsChannel));
    return null;
  });
  unawaited(_pullPendingVoice(intentsChannel));

  runApp(const JarvisCopilotApp());
}

class JarvisCopilotApp extends StatefulWidget {
  const JarvisCopilotApp({super.key});

  @override
  State<JarvisCopilotApp> createState() => _JarvisCopilotAppState();
}

class _JarvisCopilotAppState extends State<JarvisCopilotApp>
    with WidgetsBindingObserver {
  // Set true once the first frame is rendered (the home route is up). Used to
  // swallow OS-initiated route pushes that arrive AFTER boot — see
  // [didPushRouteInformation].
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Seed the foreground flag from the real initial state — covers a
    // background launch (location/audio) where main() ran but we're not actually
    // in front, so an early invoke is correctly deferred rather than run headless.
    final st = WidgetsBinding.instance.lifecycleState;
    if (st != null) AppLifecycle.isForeground = st == AppLifecycleState.resumed;
    // Sync paired creds + login-state to the native Apple Watch bridge once
    // the platform channels are wired (post first frame — the native handler
    // is registered in attachFlutterController, after main()).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _booted = true;
      WatchSync.sync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep the app-wide foreground flag current — the invoke runner uses it to
    // decide whether a foreground-required action (openURL/launch) can run now
    // or must be deferred to a notification tap.
    AppLifecycle.isForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Coming back to the foreground: re-open the live bridge immediately
      // (don't wait out the backoff) and flush any commands the server
      // queued while we were backgrounded.
      ws.pokeReconnect();
      unawaited(push.drainNow());
      // Refresh the watch's view of creds + login-state on every foreground.
      unawaited(WatchSync.sync());
      // A backgrounded app brought forward by the Lock-screen widget / Control
      // Center button / Siri has no startup pull (main() already ran), and the
      // native `startVoice` nudge can be missed mid-resume — so PULL the pending
      // flag on every resume. If set, this opens Voice + starts a turn.
      unawaited(_pullPendingVoice(const MethodChannel('jarviscopilot/intents')));
      // Run any foreground-required actions we deferred while backgrounded (the
      // user tapped the "tap to run" notification, or just reopened the app).
      unawaited(_runPendingForegroundActions());
      // Refresh the Live Activity's coding fleet on resume.
      liveActivityCoordinator.onResume();
    }
  }

  // Swallow OS-initiated route pushes once the app has booted.
  //
  // The iOS deep link behind the Dynamic Island / Lock-screen widget
  // (`jarviscopilot://voice`) is delivered to us TWICE: once natively, via
  // AppDelegate.handleIncomingURL → the pending-voice flag (the correct path,
  // which switches to the Voice tab), and AGAIN by the engine through
  // SystemChannels.navigation as a route push. That second delivery made the
  // root Navigator push a whole SECOND NavShell on top of the first — the
  // duplicate Voice screen (with a back arrow) that stacked on a Dynamic Island
  // tap. This app routes every real deep link through its own MethodChannels and
  // uses `home:` with no OS-driven named routes, so nothing legitimate arrives
  // on this channel — returning true swallows the redundant push. The framework
  // stops at the first observer that returns true (see
  // WidgetsBinding.handlePushRouteInformation), and this observer is registered
  // before MaterialApp's, so it wins. Guarded by `_booted` so the initial route
  // is never affected.
  //
  // INVARIANT: this is safe ONLY because the app has no Navigator-driven routing
  // (no named routes / go_router / Router / universal links). If that changes,
  // revisit — this would swallow those OS-driven pushes too.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    if (_booted) return true;
    return super.didPushRouteInformation(routeInformation);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JarvisCopilot',
      debugShowCheckedModeBanner: false,
      theme: JcTheme.build(),
      // Tap anywhere outside a text field to dismiss the keyboard.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      home: const _Boot(),
    );
  }
}

/// Boot gate — sends the user to the Pair page on first launch, to the
/// main bottom-nav shell once we have a stored session.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

enum _BootPhase { checking, needsPair, unreachable, ready }

class _BootState extends State<_Boot> {
  _BootPhase _phase = _BootPhase.checking;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (mounted) setState(() => _phase = _BootPhase.checking);
    if (!Credentials.instance.isPaired) {
      if (mounted) setState(() => _phase = _BootPhase.needsPair);
      return;
    }
    // Paired — but is the server actually reachable from here? Without
    // this probe the app would drop into empty Chat/Voice/etc. screens
    // when off-network. Reconnect the bridge while we're at it.
    ws.pokeReconnect();
    final ok = await api.reachable();
    if (!mounted) return;
    setState(() => _phase = ok ? _BootPhase.ready : _BootPhase.unreachable);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _BootPhase.checking:
        return const Scaffold(
          backgroundColor: JcTheme.bg,
          body: Center(child: CircularProgressIndicator()),
        );
      case _BootPhase.needsPair:
        return PairPage(onPaired: () => setState(() => _phase = _BootPhase.ready));
      case _BootPhase.unreachable:
        return _UnreachableScreen(
          serverUrl: Credentials.instance.serverUrl ?? '',
          onRetry: _check,
        );
      case _BootPhase.ready:
        return const NavShell();
    }
  }
}

/// Shown at launch when the device is paired but can't reach the server
/// (off-network, server down, VPN needed, …). Beats silently rendering
/// empty screens.
class _UnreachableScreen extends StatelessWidget {
  const _UnreachableScreen({required this.serverUrl, required this.onRetry});

  final String serverUrl;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded, size: 56, color: JcTheme.muted),
                const SizedBox(height: 18),
                const Text(
                  "Can't reach JarvisCopilot",
                  style: TextStyle(
                    color: JcTheme.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Your phone is paired but the server didn't respond. Make "
                  "sure you're on the same network (or VPN) as your server "
                  "and that it's running, then try again.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: JcTheme.muted, fontSize: 14, height: 1.4),
                ),
                if (serverUrl.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: JcTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: JcTheme.border),
                    ),
                    child: Text(
                      serverUrl,
                      style: const TextStyle(
                        color: JcTheme.muted,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'If it keeps failing, fully close and reopen the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: JcTheme.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

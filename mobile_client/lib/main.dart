import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nav.dart';
import 'pages/pair_page.dart';
import 'services/api_client.dart';
import 'services/background_location.dart';
import 'services/credentials.dart';
import 'services/invoke_runner.dart';
import 'services/push_handler.dart';
import 'services/watch_sync.dart';
import 'services/ws_bridge.dart';
import 'skills/registry.dart';
import 'skills/common.dart' as common_skills;
import 'theme.dart';
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

  // Siri "Talk to JarvisCopilot" intent → native fires this → open Voice.
  const MethodChannel('jarviscopilot/intents').setMethodCallHandler((call) async {
    if (call.method == 'startVoice') requestVoiceLaunch();
    return null;
  });

  runApp(const JarvisCopilotApp());
}

class JarvisCopilotApp extends StatefulWidget {
  const JarvisCopilotApp({super.key});

  @override
  State<JarvisCopilotApp> createState() => _JarvisCopilotAppState();
}

class _JarvisCopilotAppState extends State<JarvisCopilotApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Sync paired creds + login-state to the native Apple Watch bridge once
    // the platform channels are wired (post first frame — the native handler
    // is registered in attachFlutterController, after main()).
    WidgetsBinding.instance.addPostFrameCallback((_) => WatchSync.sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Coming back to the foreground: re-open the live bridge immediately
      // (don't wait out the backoff) and flush any commands the server
      // queued while we were backgrounded.
      ws.pokeReconnect();
      unawaited(push.drainNow());
      // Refresh the watch's view of creds + login-state on every foreground.
      unawaited(WatchSync.sync());
    }
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

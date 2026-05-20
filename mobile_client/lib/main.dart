import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nav.dart';
import 'pages/pair_page.dart';
import 'services/api_client.dart';
import 'services/credentials.dart';
import 'services/invoke_runner.dart';
import 'services/push_handler.dart';
import 'services/ws_bridge.dart';
import 'skills/registry.dart';
import 'skills/common.dart' as common_skills;
import 'theme.dart';

/// Top-level service handles wired by [main]. The Service binds Flutter
/// to the running platform; we keep these as singletons because the WS
/// bridge and skill runner share state across routes.
late final ApiClient api;
late final WsBridge ws;
late final InvokeRunner runner;
late final PushHandler push;

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

  ws.attachRunner(runner);
  unawaited(ws.start());
  unawaited(push.start());

  runApp(const JarvisCopilotApp());
}

class JarvisCopilotApp extends StatelessWidget {
  const JarvisCopilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JarvisCopilot',
      debugShowCheckedModeBanner: false,
      theme: JcTheme.build(),
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

class _BootState extends State<_Boot> {
  bool _ready = false;
  bool _paired = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final paired = Credentials.instance.isPaired;
    if (!mounted) return;
    setState(() {
      _paired = paired;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_paired) {
      return PairPage(onPaired: () {
        setState(() => _paired = true);
      });
    }
    return const NavShell();
  }
}

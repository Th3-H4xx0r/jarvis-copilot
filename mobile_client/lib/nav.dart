import 'dart:io';

import 'package:flutter/material.dart';

import 'main.dart' as app;
import 'pages/chat_page.dart';
import 'pages/devices_page.dart';
import 'pages/more_page.dart';
import 'pages/skills_page.dart';
import 'pages/voice_page.dart';
import 'services/android_accessibility.dart';
import 'theme.dart';

/// 5-tab bottom-nav shell. The 5 native tabs hit the hot paths; the
/// More tab opens a grid of webview launchers for the rest of the
/// server tabs (Tasks, Kanban, Memory, …).
class NavShell extends StatefulWidget {
  const NavShell({super.key});

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> {
  static bool _accessibilityPromptShown = false;
  int _index = 0;

  final _pages = const [
    ChatPage(),
    VoicePage(),
    SkillsPage(),
    DevicesPage(),
    MorePage(),
  ];

  @override
  void initState() {
    super.initState();
    // Cold launch via the Siri intent: the request may already be latched
    // before we mounted, so honour it as the initial tab.
    if (app.voiceLaunchRequested.value) _index = 1;
    app.voiceLaunchRequested.addListener(_onVoiceLaunch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybePromptAccessibility();
    });
  }

  @override
  void dispose() {
    app.voiceLaunchRequested.removeListener(_onVoiceLaunch);
    super.dispose();
  }

  // Siri / wake word asked to open Voice — jump to that tab (VoicePage
  // listens to the same latch and starts the turn).
  void _onVoiceLaunch() {
    if (mounted && app.voiceLaunchRequested.value && _index != 1) {
      setState(() => _index = 1);
    }
  }

  Future<void> _maybePromptAccessibility() async {
    if (!Platform.isAndroid || _accessibilityPromptShown) return;
    _accessibilityPromptShown = true;
    final enabled = await AndroidAccessibility.isEnabled();
    if (!mounted || enabled) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enable device control?'),
        content: const Text(
          'Accessibility access lets JarvisCopilot use skills like typing, '
          'tapping, and richer app control on this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final opened = await AndroidAccessibility.openSettings();
              if (!opened) {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text('Rebuild and reinstall the app to enable this settings shortcut.'),
                  ),
                );
              }
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: _pages),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.graphic_eq),
            activeIcon: Icon(Icons.graphic_eq, color: JcTheme.accent),
            label: 'Voice',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bolt_outlined),
            activeIcon: Icon(Icons.bolt),
            label: 'Skills',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.devices_other_outlined),
            activeIcon: Icon(Icons.devices_other),
            label: 'Devices',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.apps_outlined),
            activeIcon: Icon(Icons.apps),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

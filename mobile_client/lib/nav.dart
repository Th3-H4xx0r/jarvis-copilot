import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'widgets/glass.dart';
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

  static const _tabs = [
    (Icons.chat_bubble_outline, Icons.chat_bubble_rounded, 'Chat'),
    (Icons.graphic_eq_rounded, Icons.graphic_eq_rounded, 'Voice'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome_rounded, 'Skills'),
    (Icons.devices_other_outlined, Icons.devices_other_rounded, 'Devices'),
    (Icons.grid_view_outlined, Icons.grid_view_rounded, 'More'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      backgroundColor: JcTheme.bg,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: IndexedStack(index: _index, children: _pages),
        ),
      ),
      bottomNavigationBar: _GlassNavBar(
        index: _index,
        tabs: _tabs,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// Floating frosted-glass bottom nav. Active tab gets an iridescent pill +
/// gradient icon; the others are muted. Blurs the content scrolling beneath it.
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.index,
    required this.tabs,
    required this.onTap,
  });

  final int index;
  final List<(IconData, IconData, String)> tabs;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 10 + bottomInset),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xCC0E0E18),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: JcTheme.glassBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Expanded(child: _item(i)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(int i) {
    final active = i == index;
    final (outline, filled, label) = tabs[i];
    final icon = Icon(active ? filled : outline,
        size: 22, color: active ? Colors.white : JcTheme.muted);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onTap(i),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(horizontal: active ? 16 : 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: active ? iridescentGradient() : null,
              borderRadius: BorderRadius.circular(18),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: const Color(0xFF8A7CFF).withValues(alpha: 0.4),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                if (active) ...[
                  const SizedBox(width: 7),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

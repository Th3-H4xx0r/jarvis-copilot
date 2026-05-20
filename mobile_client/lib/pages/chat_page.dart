import 'package:flutter/material.dart';

import 'webview_page.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebViewPage(
      title: 'Chat',
      path: '/',
      showAppBar: false,
      popOnWebRoot: false,
      mobileShell: false,
    );
  }
}

import 'package:flutter/material.dart';

import '../theme.dart';

/// Round gradient disc with "JC" centered — the brand mark used on the
/// pair page, settings page, and webview launcher tiles.
class JcLogo extends StatelessWidget {
  const JcLogo({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: JcTheme.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.25),
        boxShadow: const [
          BoxShadow(
            color: Color(0x668A7CFF),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        'JC',
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

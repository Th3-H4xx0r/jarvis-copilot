import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared "dark glass + iridescent" primitives. Every screen composes from
/// these so the visual identity stays consistent and tunable from one place.
///
/// Perf note: BackdropFilter blur is GPU-costly. [GlassCard]/[GlassPanel] cap
/// the blur sigma and fall back to a semi-opaque fill when [blur] is false, so
/// screens with many glass elements (lists) can opt out per-item.

/// The brand iridescent gradient: cyan → violet → pink.
const List<Color> kIridescent = [
  Color(0xFF46E0E0),
  Color(0xFF8A7CFF),
  Color(0xFFFF6FD8),
];

LinearGradient iridescentGradient({
  AlignmentGeometry begin = Alignment.topLeft,
  AlignmentGeometry end = Alignment.bottomRight,
}) =>
    LinearGradient(begin: begin, end: end, colors: kIridescent);

/// A frosted-glass container: translucent fill + hairline border + optional
/// backdrop blur.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = true,
    this.fill,
    this.borderColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool blur;
  final Color? fill;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill ?? JcTheme.glassFill,
        borderRadius: r,
        border: Border.all(color: borderColor ?? JcTheme.glassBorder, width: 1),
      ),
      child: child,
    );
    if (blur) {
      content = ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: content,
        ),
      );
    }
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        borderRadius: r,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return content;
  }
}

/// Text painted with the iridescent gradient (for headings / brand marks).
class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (b) => iridescentGradient().createShader(b),
      blendMode: BlendMode.srcIn,
      child: Text(text, textAlign: textAlign, style: style),
    );
  }
}

/// Primary action: gradient-filled pill. [ghost] = transparent glass variant.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.ghost = false,
    this.full = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool ghost;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final child = Row(
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: ghost ? JcTheme.text : Colors.white),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: ghost ? JcTheme.text : Colors.white,
          ),
        ),
      ],
    );
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              gradient: ghost ? null : iridescentGradient(),
              color: ghost ? JcTheme.glassFill : null,
              borderRadius: BorderRadius.circular(16),
              border: ghost
                  ? Border.all(color: JcTheme.glassBorder, width: 1)
                  : null,
              boxShadow: ghost
                  ? null
                  : [
                      BoxShadow(
                        color: const Color(0xFF8A7CFF).withValues(alpha: 0.35),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The app's signature backdrop: a dark vertical gradient with two faint
/// iridescent glows in the corners. Use as the Scaffold background.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [JcTheme.bgTop, JcTheme.bg],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            right: -100,
            child: _glow(const Color(0xFF8A7CFF), 320),
          ),
          Positioned(
            bottom: -140,
            left: -120,
            child: _glow(const Color(0xFF46E0E0), 300),
          ),
          child,
        ],
      ),
    );
  }

  Widget _glow(Color c, double d) => IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [c.withValues(alpha: 0.16), c.withValues(alpha: 0.0)],
            ),
          ),
        ),
      );
}

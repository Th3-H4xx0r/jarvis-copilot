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

/// Primary CTA gradient — a glossy blue (the reference's mic / send / get-pro
/// colour). Use [JcTheme.primaryBlue] for single-colour blue.
LinearGradient blueGradient({
  AlignmentGeometry begin = const Alignment(-0.3, -0.6),
  AlignmentGeometry end = Alignment.bottomRight,
}) =>
    LinearGradient(begin: begin, end: end, colors: const [
      JcTheme.primaryBlueHi,
      JcTheme.primaryBlue,
      JcTheme.primaryBlueLo,
    ]);

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

/// The app's signature backdrop (matches the design reference + voice screen):
/// a near-black gradient with faint aurora glows — cool teal/blue up top, a warm
/// hint low-left. Use as EVERY screen's background; pair with a transparent
/// Scaffold so it shows through.
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
          colors: [Color(0xFF0A0C12), Color(0xFF050608)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(top: -60, left: -50, child: _glow(const Color(0xFF1EA89C), 340, 0.12)),
          Positioned(top: 20, right: -90, child: _glow(const Color(0xFF2E6BFF), 360, 0.08)),
          Positioned(bottom: -40, left: -70, child: _glow(const Color(0xFFB0703A), 300, 0.05)),
          Positioned(bottom: 80, right: -60, child: _glow(const Color(0xFF3A6BFF), 300, 0.06)),
          child,
        ],
      ),
    );
  }

  Widget _glow(Color c, double d, double a) => IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [c.withValues(alpha: a), c.withValues(alpha: 0.0)],
            ),
          ),
        ),
      );
}

/// A circular frosted icon button — the reference's back / action chips. 40px
/// translucent circle + hairline border + thin-line icon.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 20,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: JcTheme.glassFill,
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Icon(icon, size: iconSize, color: color ?? JcTheme.text),
        ),
      ),
    );
  }
}

/// A frosted AppBar matching the reference: transparent, centred title, a
/// circular [GlassIconButton] back chip, optional trailing chip.
PreferredSizeWidget glassAppBar(
  BuildContext context, {
  required String title,
  bool back = true,
  VoidCallback? onBack,
  Widget? trailing,
}) {
  return AppBar(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: true,
    titleSpacing: 0,
    leadingWidth: back ? 60 : 0,
    leading: back
        ? Padding(
            padding: const EdgeInsets.only(left: 16),
            child: GlassIconButton(
              icon: Icons.chevron_left_rounded,
              iconSize: 24,
              onTap: onBack ?? () => Navigator.of(context).maybePop(),
            ),
          )
        : null,
    title: Text(title,
        style: const TextStyle(
            color: JcTheme.text, fontSize: 18, fontWeight: FontWeight.w700)),
    actions: [
      if (trailing != null) Padding(padding: const EdgeInsets.only(right: 16), child: trailing),
    ],
  );
}

/// A bold section heading (the reference's "Extra features").
Widget glassSectionLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Text(text,
          style: const TextStyle(
              color: JcTheme.text, fontSize: 18, fontWeight: FontWeight.w700)),
    );

/// A rounded frosted container that groups [GlassRow]s (iOS inset-list style).
class GlassGroup extends StatelessWidget {
  const GlassGroup({super.key, required this.children, this.blur = true});
  final List<Widget> children;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(22);
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: r,
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Column(children: children),
    );
    if (blur) {
      content = ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: content,
        ),
      );
    }
    return content;
  }
}

/// A tappable list row: circular frosted icon + title (+ subtitle) + chevron.
class GlassRow extends StatelessWidget {
  const GlassRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.last = false,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool last;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? JcTheme.danger : JcTheme.text;
    return Column(
      children: [
        ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: _circleIcon(icon, color: danger ? JcTheme.danger : null),
          title: Text(title,
              style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
          trailing: trailing ??
              Icon(Icons.chevron_right_rounded,
                  color: JcTheme.muted.withValues(alpha: 0.7)),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
    );
  }

  static Widget _circleIcon(IconData icon, {Color? color}) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (color ?? JcTheme.text).withValues(alpha: 0.10),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        child: Icon(icon, size: 20, color: color ?? JcTheme.text),
      );
}

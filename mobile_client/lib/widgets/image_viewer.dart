import 'package:flutter/material.dart';

import '../theme.dart';

/// Fullscreen image viewer opened by tapping a chat image (see
/// [MarkdownStream]'s imageBuilder). Dark canvas + a transparent app bar with a
/// back button; the body is pinch-zoomable via [InteractiveViewer].
///
/// Dependency-free on purpose — it takes an already-resolved [ImageProvider]
/// (a MemoryImage built from bytes we already decoded/fetched for the inline
/// thumbnail), so opening the viewer never triggers a re-fetch or re-decode.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.image});

  /// The fully-resolved image to show (reuse the inline image's provider).
  final ImageProvider image;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: JcTheme.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: InteractiveViewer(
        minScale: 0.8,
        maxScale: 5,
        child: Center(
          child: Image(
            image: image,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text(
              '🖼 image',
              style: TextStyle(color: JcTheme.muted, fontSize: 15),
            ),
          ),
        ),
      ),
    );
  }
}

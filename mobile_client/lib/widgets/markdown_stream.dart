import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../main.dart' as app;
import '../theme.dart';
import 'image_viewer.dart';

/// A markdown widget that updates as text grows. We could re-create
/// MarkdownBody on every frame and let Flutter diff, but for long
/// streams that's expensive — instead we hold our own buffer and
/// rebuild only when the input actually changes. The trade-off is
/// that mid-stream the markdown may render partial syntax (an opening
/// "```" without a closing fence) and the renderer falls back to
/// inline rendering until the close arrives, which is the same
/// behaviour the webui shows.
///
/// Images are rendered (not shown as raw text) in two forms:
///   * `MEDIA:<ref>` directives (server image gen) — see [_rewriteMedia],
///     which mirrors the webui (static/ui.js renderMd MEDIA stash). HTTP(s)
///     refs become `![image](url)`; local/abs paths become
///     `![image](<base>/api/media?path=…)`.
///   * markdown data-URL images `![alt](data:image/png;base64,…)` from the
///     on-device model.
/// Both flow through [imageBuilder] below, which fetches cookie-gated bytes via
/// the shared [ApiClient] and renders `Image.memory`/`Image.network` with a
/// width clamp + a graceful "🖼 image" fallback so a broken or oversized image
/// never crashes the layout.
class MarkdownStream extends StatelessWidget {
  const MarkdownStream({super.key, required this.text, this.style});

  final String text;
  final MarkdownStyleSheet? style;

  // Image file extensions we render inline (mirrors the webui _IMAGE_EXTS).
  static final RegExp _imageExt = RegExp(
      r'\.(png|jpe?g|gif|webp|bmp|ico|avif)$',
      caseSensitive: false);

  // MEDIA:<path-or-url> tokens emitted by the agent. Stop at whitespace, ')'
  // or ']' so the ref isn't swallowed into surrounding markdown.
  static final RegExp _mediaRe = RegExp(r'MEDIA:([^\s)\]]+)');

  /// Decoded-bytes cache for data-URL images, keyed by the data string, so
  /// scrolling a long thread doesn't re-base64-decode every frame.
  static final Map<String, Uint8List> _dataCache = {};

  @override
  Widget build(BuildContext context) {
    final rendered = _rewriteMedia(text);
    return MarkdownBody(
      data: rendered.isEmpty ? '…' : rendered,
      selectable: true,
      softLineBreak: true,
      imageBuilder: (uri, title, alt) => _buildImage(context, uri, alt),
      styleSheet: style ??
          MarkdownStyleSheet(
            p: const TextStyle(
              color: JcTheme.text,
              fontSize: 14,
              height: 1.45,
            ),
            code: const TextStyle(
              fontFamily: 'monospace',
              color: JcTheme.accent,
              backgroundColor: Color(0x33000000),
            ),
            codeblockDecoration: BoxDecoration(
              color: const Color(0xFF0F1830),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: JcTheme.border),
            ),
            h1: const TextStyle(
                color: JcTheme.text,
                fontSize: 22,
                fontWeight: FontWeight.w700),
            h2: const TextStyle(
                color: JcTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w700),
            blockquoteDecoration: BoxDecoration(
              border: const Border(
                left: BorderSide(color: JcTheme.accent, width: 3),
              ),
              color: JcTheme.surfaceAlt.withValues(alpha: 0.5),
            ),
          ),
    );
  }

  /// Pre-pass: turn `MEDIA:<ref>` tokens into markdown images (or a tappable
  /// link for non-image media), so the imageBuilder can render them. Mirrors
  /// the webui's MEDIA stash/restore (static/ui.js).
  String _rewriteMedia(String input) {
    if (!input.contains('MEDIA:')) return input;
    return input.replaceAllMapped(_mediaRe, (m) {
      final ref = m.group(1) ?? '';
      if (ref.isEmpty) return m.group(0)!;
      final isHttp = RegExp(r'^https?://', caseSensitive: false).hasMatch(ref);
      // Strip a query string before the extension test (e.g. ?w=512).
      final pathPart = ref.split('?').first;
      final isImage = _imageExt.hasMatch(pathPart);
      if (isHttp) {
        // Render any http(s) MEDIA as an image (extensionless CDN paths still
        // resolve, matching the webui). The imageBuilder loads it cookie-gated.
        return '![image]($ref)';
      }
      if (isImage) {
        // Local/abs path → load via the cookie-gated media endpoint.
        final url = '${_apiBase()}/api/media?path=${Uri.encodeComponent(ref)}';
        return '![image]($url)';
      }
      // Non-image local media: leave as a plain tappable link.
      return ref;
    });
  }

  static String _apiBase() {
    try {
      return app.api.base;
    } catch (_) {
      return '';
    }
  }

  Widget _buildImage(BuildContext context, Uri uri, String? alt) {
    // Clamp to the available width so a huge image can't blow out the bubble.
    final maxW = MediaQuery.of(context).size.width;
    Widget clamp(Widget child) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        );

    Widget broken() => _BrokenImageChip();

    // Wrap an inline image so tapping it opens the fullscreen viewer. The
    // imageBuilder gives us no BuildContext, so grab one via Builder; reuse the
    // SAME bytes (as a MemoryImage) for the viewer so it never re-fetches.
    Widget tappable(Widget child, Uint8List bytes) => Builder(
          builder: (ctx) => GestureDetector(
            onTap: () => Navigator.of(ctx).push(MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => ImageViewerPage(image: MemoryImage(bytes)),
            )),
            child: child,
          ),
        );

    // data:image/…;base64,… — decode (cached) and render from memory.
    if (uri.scheme == 'data') {
      final raw = uri.toString();
      try {
        final bytes = _dataCache[raw] ??= _decodeDataUri(uri);
        if (bytes.isEmpty) return broken();
        return clamp(tappable(
          Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => broken(),
          ),
          bytes,
        ));
      } catch (_) {
        return broken();
      }
    }

    // http(s) — fetch through the ApiClient so the session cookie is sent
    // (/api/media is cookie-gated and Image.network wouldn't include it).
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final url = uri.toString();
      return clamp(FutureBuilder<Uint8List>(
        future: _fetchBytes(url),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 48,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final data = snap.data;
          if (snap.hasError || data == null || data.isEmpty) return broken();
          return tappable(
            Image.memory(
              data,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => broken(),
            ),
            data,
          );
        },
      ));
    }

    return broken();
  }

  // Cache fetched URL bytes so re-layout/scroll doesn't refetch.
  static final Map<String, Future<Uint8List>> _urlCache = {};

  static Future<Uint8List> _fetchBytes(String url) {
    return _urlCache[url] ??= app.api.getBytes(url, absoluteUrl: true);
  }

  static Uint8List _decodeDataUri(Uri uri) {
    final data = uri.data;
    if (data != null) return data.contentAsBytes();
    // Fallback: manual split on the comma (mirrors lib/skills/common.dart).
    final raw = uri.toString();
    final comma = raw.indexOf(',');
    if (comma < 0) return Uint8List(0);
    return base64Decode(raw.substring(comma + 1));
  }
}

/// Small inline fallback shown when an image can't load — keeps layout safe.
class _BrokenImageChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: JcTheme.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: JcTheme.border),
      ),
      child: const Text('🖼 image',
          style: TextStyle(color: JcTheme.muted, fontSize: 13)),
    );
  }
}

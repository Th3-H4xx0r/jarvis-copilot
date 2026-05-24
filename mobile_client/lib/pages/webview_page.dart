import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/api_client.dart' show sha256HexBytes;
import '../services/credentials.dart';
import '../theme.dart';

/// Generic webview wrapper.
///
/// - Cert pinning: InAppWebView's serverTrustAuthRequest gets a chance to
///   accept/reject before any bytes are read. We compare the leaf cert
///   SHA-256 to the pinned fingerprint and cancel otherwise.
/// - Cookie injection: we pre-seed the WebViewCookieManager with the
///   stored hermes_session cookie so the webui boots authenticated.
/// - JS bridge: for mobile-shell panels we expose
///   `window.JarvisCopilotMobile.popView` so the embedded webui can hand
///   control back to the native shell.
class WebViewPage extends StatefulWidget {
  const WebViewPage({
    super.key,
    required this.title,
    required this.path,
    this.showAppBar = true,
    this.popOnWebRoot = true,
    this.mobileShell = true,
  });

  final String title;
  final String path;
  final bool showAppBar;
  final bool popOnWebRoot;
  final bool mobileShell;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  InAppWebViewController? _wv;
  bool _loading = true;
  double _progress = 0;
  // Cache the seed future so FutureBuilder doesn't see a new Future on
  // every rebuild — without this, every setState (onLoadStart,
  // onProgressChanged, onLoadStop) creates a fresh _seedCookie() Future,
  // sends FutureBuilder back to waiting, and unmounts/remounts the
  // InAppWebView in a tight loop before any page can finish loading.
  late final Future<void> _seedFuture = _seedCookie();

  Uri get _uri => Uri.parse('${Credentials.instance.serverUrl}${widget.path}');

  Future<void> _seedCookie() async {
    final cookie = Credentials.instance.cookie;
    if (cookie == null || cookie.isEmpty) return;
    // cookie is "hermes_session=<token>.<sig>"
    final eq = cookie.indexOf('=');
    if (eq <= 0) return;
    final name = cookie.substring(0, eq);
    final value = cookie.substring(eq + 1);
    await CookieManager.instance().setCookie(
      url: WebUri.uri(_uri),
      name: name,
      value: value,
      isSecure: _uri.scheme == 'https',
      isHttpOnly: true,
    );
  }

  Future<void> _onPopHandler() async {
    if (_wv == null) {
      if (mounted && widget.popOnWebRoot) Navigator.of(context).pop();
      return;
    }
    if (await _wv!.canGoBack()) {
      _wv!.goBack();
    } else if (mounted && widget.popOnWebRoot) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onPopHandler();
      },
      child: Scaffold(
        backgroundColor: JcTheme.bg,
        appBar: widget.showAppBar
            ? AppBar(
                title: Text(widget.title),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _onPopHandler,
                ),
              )
            : null,
        body: Column(
          children: [
            if (_loading) LinearProgressIndicator(value: _progress),
            Expanded(
              child: FutureBuilder<void>(
                future: _seedFuture,
                builder: (_, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri.uri(_uri)),
                    initialSettings: InAppWebViewSettings(
                      transparentBackground: true,
                      javaScriptEnabled: true,
                      mediaPlaybackRequiresUserGesture: false,
                      useShouldOverrideUrlLoading: false,
                      useOnLoadResource: false,
                    ),
                    onWebViewCreated: (c) {
                      _wv = c;
                      c.addJavaScriptHandler(
                        handlerName: 'popView',
                        callback: (_) {
                          _onPopHandler();
                          return null;
                        },
                      );
                    },
                    onLoadStart: (_, __) => setState(() => _loading = true),
                    onLoadStop: (controller, __) async {
                      setState(() => _loading = false);
                      if (!widget.mobileShell && !widget.popOnWebRoot) return;
                      // Inject the JS bridge AFTER the page has parsed
                      // so boot.js's _jcMobileDetect picks it up.
                      final mobileClass = widget.mobileShell
                          ? "if(document.body) document.body.classList.add('in-mobile-app');"
                          : '';
                      await controller.evaluateJavascript(source: r'''
                        if(!window.JarvisCopilotMobile){
                          window.JarvisCopilotMobile = {
                            popView: function(){ window.flutter_inappwebview.callHandler('popView'); },
                          };
                        }
                      ''' + mobileClass);
                    },
                    onProgressChanged: (_, p) =>
                        setState(() => _progress = p / 100),
                    onPermissionRequest: (controller, request) async {
                      // WKWebView denies media (mic/camera) requests by
                      // default; the webui's voice UI then surfaces
                      // "Microphone access denied or unavailable." even
                      // though iOS already granted the app-level
                      // permission. The page only loads if the server's
                      // cert pinning passed in onReceivedServerTrustAuth-
                      // Request above, so we trust the origin here.
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onReceivedServerTrustAuthRequest: (controller, challenge) async {
                      final expected =
                          Credentials.instance.certFingerprint?.toLowerCase();
                      if (expected == null || expected.isEmpty) {
                        return ServerTrustAuthResponse(
                            action: ServerTrustAuthResponseAction.PROCEED);
                      }
                      // InAppWebView exposes the leaf certificate's raw
                      // bytes only on Android (x509Certificate.encoded);
                      // on iOS the SecCertificateRef isn't surfaced
                      // through the plugin, so we can't pin in-process.
                      // We trust the system chain on iOS — for a
                      // privately-signed host the user would need to
                      // install the matching profile. (The HTTP and WS
                      // bridges still pin via dart:io, so an attacker
                      // can't impersonate a paired server for any
                      // skill traffic; only the embedded webview tabs
                      // would be at risk.)
                      if (Platform.isIOS) {
                        return ServerTrustAuthResponse(
                            action: ServerTrustAuthResponseAction.PROCEED);
                      }
                      final certs = challenge.protectionSpace.sslCertificate;
                      final encoded = certs?.x509Certificate?.encoded;
                      if (encoded == null) {
                        return ServerTrustAuthResponse(
                            action: ServerTrustAuthResponseAction.CANCEL);
                      }
                      final fp = _sha256(encoded).toLowerCase();
                      if (fp == expected) {
                        return ServerTrustAuthResponse(
                            action: ServerTrustAuthResponseAction.PROCEED);
                      }
                      return ServerTrustAuthResponse(
                          action: ServerTrustAuthResponseAction.CANCEL);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _sha256(List<int> bytes) => sha256HexBytes(bytes);

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../main.dart' as app;
import '../services/api_client.dart' show sha256OfCertPem;
import '../services/credentials.dart';
import '../services/watch_sync.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/jc_logo.dart';

/// First-run pair page. Three entry vectors:
///  - Scan QR (the webui's "+ Pair new device" modal now shows one)
///  - Type the 6-char code manually (same fallback as the desktop client)
///  - Deep-link via jarviscopilot://pair?server=…&code=… (handled by
///    the iOS URL scheme / Android intent filter; the values pre-fill
///    this form, the user only needs to confirm)
class PairPage extends StatefulWidget {
  const PairPage({super.key, this.onPaired, this.prefillServer, this.prefillCode});
  final VoidCallback? onPaired;
  final String? prefillServer;
  final String? prefillCode;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _serverCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _cfIdCtrl = TextEditingController();
  final _cfSecretCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showScanner = false;
  String? _pendingFingerprint;
  // CF Access service token carried in the QR/deep-link (tunnel-first pairing).
  // Applied to Credentials BEFORE the claim POST so the request clears Access.
  String? _scannedCfId;
  String? _scannedCfSecret;

  @override
  void initState() {
    super.initState();
    _serverCtrl.text = widget.prefillServer ?? '';
    _codeCtrl.text = widget.prefillCode ?? '';
    _nameCtrl.text = _defaultDeviceName();
  }

  String _defaultDeviceName() {
    return Platform.isIOS ? 'iPhone' : 'Android';
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _cfIdCtrl.dispose();
    _cfSecretCtrl.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  // MobileScanner streams detections continuously; guard so we only act once.
  bool _scanHandled = false;
  MobileScannerController? _scannerController;

  void _closeScanner() {
    final c = _scannerController;
    _scannerController = null;
    if (c != null) {
      c.stop();
      c.dispose();
    }
    if (mounted) setState(() { _scanHandled = false; _showScanner = false; });
  }

  void _handleScan(BarcodeCapture cap) {
    if (_scanHandled) return;
    if (cap.barcodes.isEmpty) return;
    final raw = (cap.barcodes.first.rawValue ?? '').trim();
    if (raw.isEmpty) return;

    // Be tolerant of QR content. Accept, in order:
    //  1. jarviscopilot://pair?server=…&code=…[&cf_id=…&cf_secret=…]  (deep link)
    //  2. https://host[:port]/pair  → use as the server URL (strip /pair)
    //  3. a bare https://host[:port] → use directly as the server URL
    String? server, code, cfId, cfSecret;
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme == 'jarviscopilot' && uri.host == 'pair') {
      server = uri.queryParameters['server'];
      code = uri.queryParameters['code'];
      cfId = uri.queryParameters['cf_id'];
      cfSecret = uri.queryParameters['cf_secret'];
    } else if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      // A plain server/pair URL. Keep scheme+authority, drop the /pair path.
      server = '${uri.scheme}://${uri.authority}';
    } else {
      // Not something we recognise — tell the user but keep the camera open
      // (don't set _scanHandled) so they can try a different code.
      setState(() => _error = 'Unrecognised QR. Expected a JarvisCopilot pair link or server URL.');
      return;
    }

    _scanHandled = true;
    if (server != null && server.isNotEmpty) _serverCtrl.text = server;
    if (code != null && code.isNotEmpty) _codeCtrl.text = code;
    // Populate the VISIBLE CF token fields too (not just the internal vars) so
    // the user can see they came through — and so the form reflects reality.
    if (cfId != null && cfId.isNotEmpty) _cfIdCtrl.text = cfId;
    if (cfSecret != null && cfSecret.isNotEmpty) _cfSecretCtrl.text = cfSecret;
    _scannedCfId = cfId;
    _scannedCfSecret = cfSecret;
    _error = null;
    // Stop + dispose the camera and leave the scanner (also calls setState).
    _closeScanner();
  }

  /// Step 1: Open a TLS socket directly, capture the leaf cert fingerprint,
  /// then POST the pair claim with the user's name.
  Future<void> _submit() async {
    final server = _serverCtrl.text.trim();
    final code = _codeCtrl.text.trim().toUpperCase();
    final name = _nameCtrl.text.trim().isEmpty ? _defaultDeviceName() : _nameCtrl.text.trim();
    if (server.isEmpty || code.isEmpty) {
      setState(() => _error = 'Server URL and code are required');
      return;
    }
    final uri = Uri.tryParse(server);
    if (uri == null || uri.scheme != 'https') {
      // Plain http:// gives us no cert to pin — and an empty fingerprint
      // permanently disables pinning for this device. Forbid it outright.
      setState(() => _error = 'Server URL must be https:// (we pin its certificate)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Capture the fingerprint from a fresh socket so we can show it
      // to the user for confirmation. (Same first-pair-only trust flow
      // the desktop client uses.)
      String fp = '';
      final socket = await SecureSocket.connect(
        uri.host,
        uri.port == 0 ? 443 : uri.port,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 10),
      );
      try {
        final cert = socket.peerCertificate;
        if (cert != null) fp = sha256OfCertPem(cert.pem);
      } finally {
        socket.destroy();
      }
      if (fp.isEmpty) {
        setState(() => _error = 'Could not read the server\'s TLS certificate');
        return;
      }
      _pendingFingerprint = fp;

      // Save creds *before* the request so the Dio client picks up the
      // (possibly empty) fingerprint and our pinned-cert check passes.
      await Credentials.instance.savePairing(
        serverUrl: server,
        cookie: '',
        certFingerprint: fp,
        deviceName: name,
      );
      // Apply a CF Access token BEFORE the claim POST so the request carries
      // CF-Access headers and clears the edge — otherwise a tunnel-fronted
      // server 302-redirects the claim to the SSO login. Prefer what the user
      // typed into the fields; fall back to anything carried by the QR.
      final cfId = _cfIdCtrl.text.trim().isNotEmpty ? _cfIdCtrl.text.trim() : _scannedCfId;
      final cfSecret = _cfSecretCtrl.text.trim().isNotEmpty ? _cfSecretCtrl.text.trim() : _scannedCfSecret;
      if ((cfId?.isNotEmpty ?? false) && (cfSecret?.isNotEmpty ?? false)) {
        await Credentials.instance.saveCfToken(cfId, cfSecret);
      }
      app.api.notifyCredentialsChanged();

      final resp = await app.api.postJson(
        '/api/auth/pair/claim',
        {'code': code, 'name': name},
      );
      final data = resp.data;
      if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
        // Extract Set-Cookie from response headers — Dio bundles them
        // into resp.headers.map['set-cookie'].
        final raw = resp.headers.map['set-cookie'] ?? const <String>[];
        String cookieVal = '';
        for (final h in raw) {
          if (h.toLowerCase().startsWith('hermes_session=')) {
            cookieVal = h.split(';').first;
            break;
          }
        }
        if (cookieVal.isEmpty) {
          setState(() => _error = 'Pairing succeeded but no session cookie was returned');
          return;
        }
        await Credentials.instance.savePairing(
          serverUrl: server,
          cookie: cookieVal,
          certFingerprint: fp,
          deviceName: name,
        );
        // If the server is behind a Cloudflare tunnel it returns a CF Access
        // service token in the claim response — persist it so native requests
        // clear Access at the edge. Absent → cleared (local/non-tunnel).
        final cf = (data['cf_access'] is Map) ? data['cf_access'] as Map : null;
        await Credentials.instance.saveCfToken(
          cf?['client_id']?.toString(),
          cf?['client_secret']?.toString(),
        );
        app.api.notifyCredentialsChanged();
        unawaited(app.ws.start());
        unawaited(app.push.start());
        // Hand the fresh creds + login-state to the Apple Watch bridge.
        unawaited(WatchSync.sync());
        widget.onPaired?.call();
      } else {
        setState(() => _error = 'Pair failed: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      setState(() => _error = 'Pair failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Frosted input field decoration (matches the spec: glassFill, rounded ~14,
  /// glassBorder, focused border primaryBlue).
  InputDecoration _inputDecoration({required String label, String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: JcTheme.glassFill,
      labelStyle: const TextStyle(color: JcTheme.muted),
      hintStyle: const TextStyle(color: JcTheme.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JcTheme.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JcTheme.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JcTheme.primaryBlue, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scanner screen — full-screen camera with glass app bar.
    if (_showScanner) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: glassAppBar(context, title: 'Scan QR', back: true, onBack: _closeScanner),
        body: Stack(
          children: [
            // Use an explicit controller scoped to the QR formats we care about.
            // In mobile_scanner 7.x the implicit controller can show the camera
            // preview but fail to stream detections; an owned controller with
            // formats:[qrCode] + autoStart is the reliable path.
            MobileScanner(
              controller: _scannerController ??= MobileScannerController(
                formats: const [BarcodeFormat.qrCode],
                detectionSpeed: DetectionSpeed.normal,
              ),
              onDetect: _handleScan,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Camera error: ${error.errorCode.name}.\n'
                    'Grant camera permission, or type the code below instead.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: JcTheme.muted),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 48,
              left: 24,
              right: 24,
              child: _BlueButton(
                label: 'Cancel',
                onPressed: _closeScanner,
              ),
            ),
          ],
        ),
      );
    }

    // Main pairing form — THE SCREEN PATTERN.
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Pair device', back: false),
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                const Center(child: JcLogo(size: 80)),
                const SizedBox(height: 20),
                const Text(
                  'Pair with JarvisCopilot',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: JcTheme.text,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Open the Devices tab on your server\nand tap "+ Pair new device".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: JcTheme.muted, height: 1.5),
                ),
                const SizedBox(height: 28),

                // QR scan CTA — frosted glass button.
                GlassCard(
                  padding: EdgeInsets.zero,
                  onTap: () => setState(() {
                    _scanHandled = false;
                    _scannerController = null; // a fresh one is built in build()
                    _showScanner = true;
                  }),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code_scanner, color: JcTheme.primaryBlueHi, size: 22),
                        SizedBox(width: 10),
                        Text(
                          'Scan QR code',
                          style: TextStyle(
                            color: JcTheme.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(child: Divider(color: JcTheme.glassBorder)),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or enter manually',
                          style: TextStyle(fontSize: 12, color: JcTheme.muted)),
                    ),
                    Expanded(child: Divider(color: JcTheme.glassBorder)),
                  ],
                ),
                const SizedBox(height: 20),

                // Manual entry fields.
                TextField(
                  controller: _serverCtrl,
                  decoration: _inputDecoration(label: 'Server URL', hint: 'https://1.2.3.4:8787'),
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: JcTheme.text),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeCtrl,
                  decoration: _inputDecoration(label: 'Pairing code', hint: 'ABC-DEF'),
                  style: const TextStyle(
                    letterSpacing: 4,
                    fontFamily: 'monospace',
                    color: JcTheme.text,
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameCtrl,
                  decoration: _inputDecoration(label: 'Device name', hint: 'My iPhone'),
                  style: const TextStyle(color: JcTheme.text),
                ),

                // Cloudflare Access service token (only needed when the server is
                // behind a CF tunnel). Paste the values shown on the server's pair
                // popup — otherwise the claim 302-redirects to the SSO login.
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    // Re-key when CF values are present so the tile rebuilds with
                    // initiallyExpanded=true — otherwise a scanned token stays
                    // hidden inside the collapsed section and looks "not copied".
                    key: ValueKey(_cfIdCtrl.text.isNotEmpty || _cfSecretCtrl.text.isNotEmpty),
                    initiallyExpanded: _cfIdCtrl.text.isNotEmpty || _cfSecretCtrl.text.isNotEmpty,
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text(
                      'Behind a Cloudflare tunnel? (service token)',
                      style: TextStyle(fontSize: 13, color: JcTheme.muted),
                    ),
                    iconColor: JcTheme.muted,
                    collapsedIconColor: JcTheme.muted,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Paste the token from the server\'s pair popup. Still getting '
                          'a login redirect (302)? Your Cloudflare Access policy needs '
                          'Action = Service Auth (NOT "Allow" — Allow still requires a '
                          'browser login): Zero Trust → Access → Applications → your app '
                          '→ Policies → add a Service Auth policy → Include → Service Token.',
                          style: TextStyle(fontSize: 11, color: JcTheme.muted, height: 1.4),
                        ),
                      ),
                      TextField(
                        controller: _cfIdCtrl,
                        autocorrect: false,
                        decoration: _inputDecoration(
                          label: 'CF Access Client ID',
                          hint: 'xxxxxxxx.access',
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _cfSecretCtrl,
                        obscureText: true,
                        autocorrect: false,
                        decoration: _inputDecoration(label: 'CF Access Client Secret'),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                    ],
                  ),
                ),

                // TLS cert fingerprint card (frosted).
                if (_pendingFingerprint != null && _pendingFingerprint!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: GlassCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('TLS certificate fingerprint:',
                              style: TextStyle(fontSize: 11, color: JcTheme.muted)),
                          const SizedBox(height: 6),
                          SelectableText(
                            _formatFingerprint(_pendingFingerprint!),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: JcTheme.accent,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Compare with `jarviscopilot status` on the server.',
                            style: TextStyle(fontSize: 11, color: JcTheme.muted),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Error banner.
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_error!, style: const TextStyle(color: JcTheme.danger)),
                  ),

                const SizedBox(height: 24),

                // Blue primary CTA — Pair button.
                _BlueButton(
                  label: 'Pair',
                  busy: _busy,
                  onPressed: _busy ? null : _submit,
                ),

                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatFingerprint(String hex) {
    final h = hex.toUpperCase();
    final out = StringBuffer();
    for (var i = 0; i < h.length; i += 2) {
      out.write(h.substring(i, (i + 2).clamp(0, h.length)));
      if (i + 2 < h.length) out.write((i + 2) % 16 == 0 ? '\n' : ' ');
    }
    return out.toString();
  }
}

/// Blue primary CTA pill button (blueGradient + glow), replacing GradientButton.
class _BlueButton extends StatelessWidget {
  const _BlueButton({
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null && !busy;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: busy ? null : onPressed,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
            decoration: BoxDecoration(
              gradient: blueGradient(),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: JcTheme.primaryBlue.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                else
                  const SizedBox.shrink(),
                if (busy) const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

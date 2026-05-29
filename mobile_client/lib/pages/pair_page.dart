import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../main.dart' as app;
import '../services/api_client.dart' show sha256OfCertPem;
import '../services/credentials.dart';
import '../services/watch_sync.dart';
import '../theme.dart';
import '../widgets/gradient_button.dart';
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
  bool _busy = false;
  String? _error;
  bool _showScanner = false;
  String? _pendingFingerprint;

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
    super.dispose();
  }

  void _handleScan(BarcodeCapture cap) {
    if (cap.barcodes.isEmpty) return;
    final raw = cap.barcodes.first.rawValue ?? '';
    if (raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'jarviscopilot' || uri.host != 'pair') {
      setState(() => _error = 'Unrecognised QR (need jarviscopilot://pair URL)');
      return;
    }
    setState(() {
      _serverCtrl.text = uri.queryParameters['server'] ?? '';
      _codeCtrl.text = uri.queryParameters['code'] ?? '';
      _showScanner = false;
      _error = null;
    });
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

  @override
  Widget build(BuildContext context) {
    if (_showScanner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan QR'), backgroundColor: JcTheme.bg),
        body: Stack(
          children: [
            MobileScanner(onDetect: _handleScan),
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: GradientButton(
                label: 'Cancel',
                onPressed: () => setState(() => _showScanner = false),
                full: true,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              const Center(child: JcLogo(size: 80)),
              const SizedBox(height: 20),
              const Text(
                'Pair with JarvisCopilot',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Open the Devices tab on your server\nand tap "+ Pair new device".',
                textAlign: TextAlign.center,
                style: TextStyle(color: JcTheme.muted, height: 1.5),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR code'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: JcTheme.text,
                    side: const BorderSide(color: JcTheme.border),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => setState(() => _showScanner = true),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),
              const Text('Or enter manually:', style: TextStyle(color: JcTheme.muted)),
              const SizedBox(height: 12),
              TextField(
                controller: _serverCtrl,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://1.2.3.4:8787',
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'ABC-DEF',
                ),
                style: const TextStyle(letterSpacing: 4, fontFamily: 'monospace'),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Device name',
                  hintText: 'My iPhone',
                ),
              ),
              if (_pendingFingerprint != null && _pendingFingerprint!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: JcTheme.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: JcTheme.border),
                    ),
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
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_error!, style: const TextStyle(color: JcTheme.danger)),
                ),
              const SizedBox(height: 24),
              GradientButton(
                label: 'Pair',
                busy: _busy,
                onPressed: _busy ? null : _submit,
                full: true,
              ),
            ],
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

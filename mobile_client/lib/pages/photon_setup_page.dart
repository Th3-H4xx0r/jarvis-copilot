import 'package:flutter/material.dart';

import '../api/photon.dart';
import '../main.dart' as app;
import '../services/api_client.dart' show apiErrorMessage;
import '../theme.dart';
import '../widgets/glass.dart';

/// Photon (hosted iMessage) provider setup. Loads the current config from
/// `/api/integrations/photon`, lets the user paste their credentials, and POSTs
/// them back.
///
/// The two SECRET fields (project secret + sidecar token) are write-only: the
/// GET never returns their values, only `*_set` booleans. When a secret is
/// already stored we show a dotted placeholder + a "saved — leave blank to keep"
/// hint, and on save we only send a secret key if the user actually typed one
/// (so a blank field preserves the stored secret).
class PhotonSetupPage extends StatefulWidget {
  const PhotonSetupPage({super.key});

  @override
  State<PhotonSetupPage> createState() => _PhotonSetupPageState();
}

class _PhotonSetupPageState extends State<PhotonSetupPage> {
  final _photon = PhotonApi(app.api);

  final _projectIdCtrl = TextEditingController();
  final _projectSecretCtrl = TextEditingController();
  final _notifyTargetCtrl = TextEditingController();
  final _sidecarUrlCtrl = TextEditingController();
  final _sidecarTokenCtrl = TextEditingController();
  final _allowedUsersCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Whether the server already has each secret stored (from `*_set`). Drives
  // the "leave blank to keep" hint + lets a blank project-secret satisfy the
  // required rule.
  bool _projectSecretSet = false;
  bool _sidecarTokenSet = false;

  static const String _dots = '••••••••';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _projectIdCtrl.dispose();
    _projectSecretCtrl.dispose();
    _notifyTargetCtrl.dispose();
    _sidecarUrlCtrl.dispose();
    _sidecarTokenCtrl.dispose();
    _allowedUsersCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cfg = await _photon.getConfig();
      if (!mounted) return;
      _projectIdCtrl.text = cfg.projectId;
      _notifyTargetCtrl.text = cfg.notifyTarget;
      // Server defaults sidecar_url to http://127.0.0.1:8787; keep whatever it
      // returns so the field is never blank unexpectedly.
      _sidecarUrlCtrl.text = cfg.sidecarUrl;
      _allowedUsersCtrl.text = cfg.allowedUsers;
      setState(() {
        _projectSecretSet = cfg.projectSecretSet;
        _sidecarTokenSet = cfg.sidecarTokenSet;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = apiErrorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final projectId = _projectIdCtrl.text.trim();
    final projectSecret = _projectSecretCtrl.text; // secrets sent verbatim
    final sidecarToken = _sidecarTokenCtrl.text;

    // Required: project_id always; project_secret unless one is already stored.
    if (projectId.isEmpty) {
      setState(() => _error = 'Project ID is required');
      return;
    }
    if (projectSecret.isEmpty && !_projectSecretSet) {
      setState(() => _error = 'Project secret is required');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final configured = await _photon.saveConfig(
        projectId: projectId,
        // Only send secrets the user actually typed — blank keeps the stored
        // value (the GET never round-trips a secret, so sending '' would wipe).
        projectSecret: projectSecret.isEmpty ? null : projectSecret,
        notifyTarget: _notifyTargetCtrl.text.trim(),
        sidecarUrl: _sidecarUrlCtrl.text.trim(),
        sidecarToken: sidecarToken.isEmpty ? null : sidecarToken,
        allowedUsers: _allowedUsersCtrl.text.trim(),
      );
      if (!mounted) return;
      // A typed secret is now stored — flip the flags + clear the inputs so the
      // "saved — leave blank to keep" hint shows on the next edit.
      setState(() {
        if (projectSecret.isNotEmpty) _projectSecretSet = true;
        if (sidecarToken.isNotEmpty) _sidecarTokenSet = true;
        _projectSecretCtrl.clear();
        _sidecarTokenCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(configured
            ? 'Photon connected — iMessage is set up.'
            : 'Saved.'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Frosted input decoration — same shape pair_page.dart uses.
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

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Text(text,
            style: const TextStyle(
                color: JcTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, left: 2),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11, color: JcTheme.muted, height: 1.4)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Photon (iMessage)', back: true),
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: JcTheme.primaryBlue))
              : SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      const Text(
                        'Connect hosted iMessage',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: JcTheme.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Create a project at app.photon.codes, then paste its '
                        'credentials from the project settings page. The Photon '
                        'sidecar must be running on your Mac for messages to send.',
                        style: TextStyle(color: JcTheme.muted, height: 1.5),
                      ),
                      const SizedBox(height: 24),

                      // Project ID (required, plain).
                      _fieldLabel('Project ID'),
                      TextField(
                        controller: _projectIdCtrl,
                        autocorrect: false,
                        decoration: _inputDecoration(
                          label: 'Project ID',
                          hint: 'proj_…',
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      const SizedBox(height: 18),

                      // Project secret (required, secret/write-only).
                      _fieldLabel('Project secret'),
                      TextField(
                        controller: _projectSecretCtrl,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: _inputDecoration(
                          label: 'Project secret',
                          hint: _projectSecretSet ? _dots : null,
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      if (_projectSecretSet)
                        _hint('Saved — leave blank to keep the stored secret.'),
                      const SizedBox(height: 18),

                      // Notify target (plain).
                      _fieldLabel('Notify target'),
                      TextField(
                        controller: _notifyTargetCtrl,
                        autocorrect: false,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _inputDecoration(
                          label: 'Notify target',
                          hint: 'phone number or email',
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      _hint('Where Jarvis sends you iMessages.'),
                      const SizedBox(height: 18),

                      // Sidecar URL (plain, defaults to local sidecar).
                      _fieldLabel('Sidecar URL'),
                      TextField(
                        controller: _sidecarUrlCtrl,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        decoration: _inputDecoration(
                          label: 'Sidecar URL',
                          hint: 'http://127.0.0.1:8787',
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      _hint('The local Photon sidecar address on your Mac.'),
                      const SizedBox(height: 18),

                      // Sidecar token (secret/write-only).
                      _fieldLabel('Sidecar token'),
                      TextField(
                        controller: _sidecarTokenCtrl,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: _inputDecoration(
                          label: 'Sidecar token',
                          hint: _sidecarTokenSet ? _dots : null,
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      if (_sidecarTokenSet)
                        _hint('Saved — leave blank to keep the stored token.'),
                      const SizedBox(height: 18),

                      // Allowed users (plain).
                      _fieldLabel('Allowed users'),
                      TextField(
                        controller: _allowedUsersCtrl,
                        autocorrect: false,
                        decoration: _inputDecoration(
                          label: 'Allowed users',
                          hint: 'comma-separated handles',
                        ),
                        style: const TextStyle(color: JcTheme.text),
                      ),
                      _hint('Who may message Jarvis. Leave blank to allow any.'),

                      // Error banner.
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text(_error!,
                              style: const TextStyle(color: JcTheme.danger)),
                        ),

                      const SizedBox(height: 26),

                      _BlueButton(
                        label: 'Save',
                        busy: _busy,
                        onPressed: _busy ? null : _save,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Blue primary CTA pill button — same widget pair_page.dart uses (kept private
/// per-file, matching that file's convention rather than introducing a shared
/// export).
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
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Colors.white),
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

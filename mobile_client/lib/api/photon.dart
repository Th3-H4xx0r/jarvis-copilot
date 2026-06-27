import '../services/api_client.dart';

/// REST wrapper for the Photon (hosted iMessage) integration config
/// (`/api/integrations/photon`).
///
/// Two SECRET fields — `project_secret` and `sidecar_token` — are write-only:
/// the GET never returns their values, only `*_set` booleans telling us whether
/// a value is already stored. On save we omit a secret key entirely when the
/// user left it blank, so a blank field preserves the stored secret server-side.
class PhotonApi {
  PhotonApi(this.api);
  final ApiClient api;

  /// GET /api/integrations/photon -> [PhotonConfig].
  Future<PhotonConfig> getConfig() async {
    final resp = await api.get('/api/integrations/photon');
    final body = (resp.data as Map?) ?? const {};
    return PhotonConfig.fromJson(Map<String, dynamic>.from(body));
  }

  /// POST /api/integrations/photon with any subset of the string config keys.
  /// Only pass a secret (`projectSecret` / `sidecarToken`) when the user typed
  /// something — leave it null to keep the stored value untouched.
  ///
  /// `allowAll` is a non-secret bool, so it's always sent. The POST response
  /// also reloads the gateway, so we parse the FULL response back into a
  /// [PhotonConfig] — the page reads its post-save `sidecar` to refresh the
  /// status indicator without leaving the page.
  ///
  /// Throws (DioException) on HTTP 400.
  Future<PhotonConfig> saveConfig({
    String? projectId,
    String? projectSecret,
    String? notifyTarget,
    String? sidecarUrl,
    String? sidecarToken,
    String? allowedUsers,
    required bool allowAll,
  }) async {
    final body = <String, dynamic>{
      if (projectId != null) 'project_id': projectId,
      if (projectSecret != null) 'project_secret': projectSecret,
      if (notifyTarget != null) 'notify_target': notifyTarget,
      if (sidecarUrl != null) 'sidecar_url': sidecarUrl,
      if (sidecarToken != null) 'sidecar_token': sidecarToken,
      if (allowedUsers != null) 'allowed_users': allowedUsers,
      // Always send — non-secret bool; no "omit to preserve" semantics.
      'allow_all': allowAll,
    };
    final resp = await api.postJson('/api/integrations/photon', body);
    final data = (resp.data as Map?) ?? const {};
    return PhotonConfig.fromJson(Map<String, dynamic>.from(data));
  }
}

/// Health/connection status of the local Photon sidecar, as reported by the
/// server in the `sidecar` object on GET and POST. `mock`/`connected`/`error`
/// are optional — absent fields default to false / empty.
class PhotonSidecar {
  const PhotonSidecar({
    this.reachable = false,
    this.ok = false,
    this.mock = false,
    this.connected = false,
    this.error = '',
  });

  final bool reachable;
  final bool ok;
  final bool mock;
  final bool connected;
  final String error;

  factory PhotonSidecar.fromJson(Map<String, dynamic> j) => PhotonSidecar(
        reachable: j['reachable'] == true,
        ok: j['ok'] == true,
        mock: j['mock'] == true,
        connected: j['connected'] == true,
        error: (j['error'] ?? '').toString(),
      );
}

/// One entry in the server-described form (`fields[]`). `kind` is the newer
/// per-field type hint ("text" | "password" | "bool"); `secret` is kept for
/// back-compat and is true whenever `kind == "password"`.
class PhotonField {
  const PhotonField({
    required this.key,
    required this.label,
    required this.secret,
    required this.required,
    this.kind = 'text',
  });

  final String key;
  final String label;
  final bool secret;
  final bool required;
  final String kind;

  factory PhotonField.fromJson(Map<String, dynamic> j) {
    final kind = (j['kind'] ?? 'text').toString();
    return PhotonField(
      key: (j['key'] ?? '').toString(),
      label: (j['label'] ?? '').toString(),
      secret: j['secret'] == true || kind == 'password',
      required: j['required'] == true,
      kind: kind,
    );
  }
}

/// The current Photon config as returned by the GET. Secret VALUES are never
/// present — only the `*Set` flags indicating whether one is stored.
class PhotonConfig {
  const PhotonConfig({
    this.fields = const [],
    this.configured = false,
    this.projectId = '',
    this.projectSecretSet = false,
    this.notifyTarget = '',
    this.sidecarUrl = '',
    this.sidecarTokenSet = false,
    this.allowedUsers = '',
    this.allowAll = false,
    this.sidecar = const PhotonSidecar(),
  });

  final List<PhotonField> fields;
  final bool configured;
  final String projectId;
  final bool projectSecretSet;
  final String notifyTarget;
  final String sidecarUrl;
  final bool sidecarTokenSet;
  final String allowedUsers;
  final bool allowAll;
  final PhotonSidecar sidecar;

  factory PhotonConfig.fromJson(Map<String, dynamic> j) {
    final rawFields = (j['fields'] as List?) ?? const [];
    final rawSidecar = j['sidecar'];
    return PhotonConfig(
      fields: rawFields
          .whereType<Map>()
          .map((m) => PhotonField.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false),
      configured: j['configured'] == true,
      projectId: (j['project_id'] ?? '').toString(),
      projectSecretSet: j['project_secret_set'] == true,
      notifyTarget: (j['notify_target'] ?? '').toString(),
      sidecarUrl: (j['sidecar_url'] ?? '').toString(),
      sidecarTokenSet: j['sidecar_token_set'] == true,
      allowedUsers: (j['allowed_users'] ?? '').toString(),
      allowAll: j['allow_all'] == true,
      sidecar: rawSidecar is Map
          ? PhotonSidecar.fromJson(Map<String, dynamic>.from(rawSidecar))
          : const PhotonSidecar(),
    );
  }
}

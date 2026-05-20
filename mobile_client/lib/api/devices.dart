import '../services/api_client.dart';

class DevicesApi {
  DevicesApi(this.api);
  final ApiClient api;

  Future<List<Map<String, dynamic>>> list() async {
    final resp = await api.get('/api/devices');
    final data = resp.data as Map;
    final raw = (data['devices'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> allSkills() async {
    final resp = await api.get('/api/devices/skills');
    final data = resp.data as Map;
    final raw = (data['skills'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  Future<void> revoke(String id) async {
    await api.deleteJson('/api/devices/$id');
  }

  Future<void> logout(String id) async {
    await api.postJson('/api/devices/$id/logout', const {});
  }

  Future<Map<String, dynamic>> startPair({int ttl = 600, String? label}) async {
    final resp = await api.postJson('/api/devices/pair/start', {
      'ttl': ttl,
      if (label != null) 'label': label,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Future<Map<String, dynamic>> invoke(
      String deviceId, String skill, Map<String, dynamic> args,
      {double timeout = 30}) async {
    final resp = await api.postJson('/api/devices/skills/invoke', {
      'device_id': deviceId,
      'skill': skill,
      'args': args,
      'timeout': timeout,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }
}

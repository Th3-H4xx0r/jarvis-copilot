import '../services/api_client.dart';

/// /api/models — list available models + active provider.
class ModelsApi {
  ModelsApi(this.api);
  final ApiClient api;

  Future<Map<String, dynamic>> list() async {
    final resp = await api.get('/api/models');
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Future<void> setActive({String? model, String? provider}) async {
    await api.postJson('/api/model/active', {
      if (model != null) 'model': model,
      if (provider != null) 'provider': provider,
    });
  }
}

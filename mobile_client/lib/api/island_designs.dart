import '../island/island_models.dart';
import '../services/api_client.dart';

/// REST wrapper for the Dynamic Island Designs API (`/api/island/*`).
///
/// The webui HTTP server has no PUT, so selection/rules use POST and deletes
/// use DELETE (with a POST `/delete` alias available server-side).
class IslandApi {
  IslandApi(this.api);
  final ApiClient api;

  /// GET /api/island/designs -> {designs, catalog, selection, data}
  Future<IslandCatalog> fetchCatalog() async {
    final resp = await api.get('/api/island/designs');
    final data = resp.data;
    if (data is! Map) return IslandCatalog.empty;
    return IslandCatalog.fromJson(Map<String, dynamic>.from(data));
  }

  /// POST /api/island/designs — create or update a design (server validates).
  Future<void> upsert(Map<String, dynamic> design) async {
    await api.postJson('/api/island/designs', design);
  }

  /// DELETE /api/island/designs/<id>
  Future<void> deleteDesign(String id) async {
    await api.deleteJson('/api/island/designs/$id');
  }

  /// POST /api/island/selection {mode, pinnedId?}
  Future<void> setSelection(String mode, {String? pinnedId}) async {
    await api.postJson('/api/island/selection', {
      'mode': mode,
      if (pinnedId != null) 'pinnedId': pinnedId,
    });
  }

  /// POST /api/island/designs/<id>/rules {enabled?, priority?, conditions?, schedule?}
  Future<void> setRules(
    String id, {
    bool? enabled,
    int? priority,
    Map<String, dynamic>? conditions,
    Map<String, dynamic>? schedule,
  }) async {
    await api.postJson('/api/island/designs/$id/rules', {
      if (enabled != null) 'enabled': enabled,
      if (priority != null) 'priority': priority,
      if (conditions != null) 'conditions': conditions,
      if (schedule != null) 'schedule': schedule,
    });
  }

  /// POST /api/island/designs/<id>/data {...values}
  Future<void> setData(String id, Map<String, dynamic> data) async {
    await api.postJson('/api/island/designs/$id/data', data);
  }
}

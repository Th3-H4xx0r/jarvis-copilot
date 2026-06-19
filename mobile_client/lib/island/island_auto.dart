import 'island_bindings.dart';
import 'island_models.dart';

/// The chosen active island: a kind (`voice`/`coding`/`custom`/`none`) plus the
/// entry id (for `custom`, the design id to render).
class IslandActive {
  const IslandActive(this.id, this.kind);
  final String? id;
  final String kind; // 'voice' | 'coding' | 'custom' | 'none'

  static const none = IslandActive(null, 'none');

  bool get isCustom => kind == 'custom';

  @override
  bool operator ==(Object other) =>
      other is IslandActive && other.id == id && other.kind == kind;
  @override
  int get hashCode => Object.hash(id, kind);
}

/// Decide which island shows right now. Pure.
///
/// Precedence:
///   1. a live voice turn always wins (it's restored after);
///   2. a PINNED entry shows literally;
///   3. AUTO picks the highest-priority enabled entry whose conditions + schedule
///      match now (voice is excluded — it only shows on an active turn; coding's
///      implicit condition is "sessions live");
///   4. nothing matches → none (resting/clear).
IslandActive selectActiveDesign({
  required IslandCatalog catalog,
  required bool voiceActive,
  required bool codingLive,
  required Sources sources,
  required DateTime now,
}) {
  if (voiceActive) return const IslandActive('voice', 'voice');

  final sel = catalog.selection;
  if (sel.isPinned) {
    final id = sel.pinnedId;
    if (id == 'voice') return const IslandActive('voice', 'voice');
    if (id == 'coding') return const IslandActive('coding', 'coding');
    if (id != null && catalog.designById(id) != null) {
      return IslandActive(id, 'custom');
    }
    // pinned to a design that no longer exists → fall through to auto
  }

  IslandCatalogEntry? best;
  for (final e in catalog.entries) {
    if (e.isVoice) continue; // voice only shows on an active turn
    if (!e.enabled) continue;
    if (e.isCoding && !codingLive) continue; // coding's implicit condition
    if (!evaluateCondition(e.conditions, sources)) continue;
    if (!scheduleMatches(e.schedule, now)) continue;
    if (best == null || e.priority > best.priority) best = e;
  }
  if (best == null) return IslandActive.none;
  return IslandActive(best.id, best.isCoding ? 'coding' : 'custom');
}

/// A schedule `{days:[1-7]?, from:"HH:MM", to:"HH:MM"}` — days use DateTime
/// weekday numbering (Mon=1 … Sun=7). Null/empty = always. A `from > to` window
/// wraps past midnight.
bool scheduleMatches(Map<String, dynamic>? schedule, DateTime now) {
  if (schedule == null || schedule.isEmpty) return true;

  final days = schedule['days'];
  if (days is List && days.isNotEmpty) {
    final wd = now.weekday; // 1..7
    final allowed = days.map((d) => d is num ? d.toInt() : int.tryParse('$d'));
    if (!allowed.contains(wd)) return false;
  }

  final from = _minutes(schedule['from']);
  final to = _minutes(schedule['to']);
  if (from == null || to == null) return true; // partial window → time always ok
  final cur = now.hour * 60 + now.minute;
  if (from <= to) return cur >= from && cur <= to;
  return cur >= from || cur <= to; // wraps midnight
}

int? _minutes(dynamic hhmm) {
  if (hhmm is! String) return null;
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

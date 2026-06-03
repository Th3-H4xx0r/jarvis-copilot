/// In-memory queue of foreground-required actions deferred while the app was
/// backgrounded. When the app returns to the foreground (notification tap or
/// manual open), main.dart drains this and runs each one (openURL now works).
///
/// In-memory is sufficient because the app stays alive in the background
/// (audio/location modes), so the action survives until the user taps. If the
/// app is fully killed before the tap, the deferred action is lost — an
/// acceptable degradation for a rare case.
class PendingAction {
  PendingAction(this.skill, this.args, this.at);
  final String skill;
  final Map<String, dynamic> args;
  final DateTime at;
}

class PendingActions {
  PendingActions._();
  static final PendingActions instance = PendingActions._();

  /// Deferred actions older than this are dropped on drain (matches the bridge
  /// expiry) so a long-ignored action doesn't fire on a much-later resume.
  static const Duration ttl = Duration(hours: 1);

  final List<PendingAction> _q = [];

  void add(String skill, Map<String, dynamic> args, {DateTime? at}) {
    _q.add(PendingAction(skill, Map<String, dynamic>.from(args), at ?? DateTime.now()));
  }

  bool get isEmpty => _q.isEmpty;
  int get length => _q.length;

  /// Remove and return all non-expired actions (expired ones are dropped).
  List<PendingAction> drainFresh({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(ttl);
    final fresh = _q.where((a) => a.at.isAfter(cutoff)).toList();
    _q.clear();
    return fresh;
  }
}

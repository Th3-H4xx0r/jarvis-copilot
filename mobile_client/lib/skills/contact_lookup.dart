import 'package:flutter_contacts/flutter_contacts.dart';

/// Resolve a send-message recipient to a concrete handle the iOS Shortcuts
/// "Send Message" action can use. Send Message fails with "couldn't convert from
/// Text to Contact, Phone Number, or Email Address" when handed loose name text
/// it can't match — so we look the name up in the device contacts FIRST and pass
/// a bare phone number (which never needs conversion). Mirrors what Siri does
/// behind the scenes.

final RegExp _phoneLike = RegExp(r'^[+()\-.\s\d]{4,}$');

/// Strip a phone number to a dialable form: digits, keeping a single leading `+`.
String cleanNumber(String raw) {
  final plus = raw.trimLeft().startsWith('+');
  final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) return raw.trim();
  return plus ? '+$digits' : digits;
}

/// Pure recipient matcher — kept free of plugins so it can be unit-tested.
/// Ranking: exact display-name match > name starts-with query > name contains
/// query. Contacts with no phone are skipped. Returns the chosen number cleaned,
/// or null when nothing matches.
String? bestContactNumber(
    List<({String name, List<String> phones})> contacts, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  ({String name, List<String> phones})? exact, prefix, sub;
  for (final c in contacts) {
    if (c.phones.every((p) => p.trim().isEmpty)) continue;
    final n = c.name.toLowerCase();
    if (n == q) {
      exact ??= c;
    } else if (n.startsWith(q)) {
      prefix ??= c;
    } else if (n.contains(q)) {
      sub ??= c;
    }
  }
  final pick = exact ?? prefix ?? sub;
  if (pick == null) return null;
  for (final p in pick.phones) {
    if (p.trim().isNotEmpty) return cleanNumber(p);
  }
  return null;
}

/// Look up `to` in the device contacts and return a dialable handle. A value
/// that already looks like a phone number is cleaned and returned as-is (no
/// lookup). On no permission / no match / any error, the original text is
/// returned so the Shortcut can still try (best-effort) — no worse than before.
Future<String> resolveRecipient(String to) async {
  final raw = to.trim();
  if (raw.isEmpty) return raw;
  if (_phoneLike.hasMatch(raw)) return cleanNumber(raw);
  try {
    final ok = await FlutterContacts.requestPermission(readonly: true);
    if (!ok) return raw;
    final all =
        await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
    final mapped = all
        .map((c) => (
              name: c.displayName,
              phones: c.phones.map((p) => p.number).toList(),
            ))
        .toList();
    return bestContactNumber(mapped, raw) ?? raw;
  } catch (_) {
    return raw;
  }
}

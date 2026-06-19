import 'island_models.dart';

/// Binding resolution + condition evaluation for Dynamic Island designs.
///
/// The iOS widget reads element values out of the pushed `data` map (both
/// `{"$":k}` and `{"src":k}` look up `data[k]`). This file is the AWAKE-path
/// upstream resolver: it merges server-resolved values with whatever live
/// sources the client knows, and evaluates auto-rule conditions against that
/// same source map. Pure + side-effect-free so it's trivially testable.

typedef Sources = Map<String, dynamic>;

/// Build the `data` map to push for [design]: server values overlaid with any
/// client-known source values the design actually references. Keys are the
/// source/`$` strings the design binds to (so the widget's `data[k]` lookup
/// resolves). Unknown sources are simply absent → the widget renders nothing.
Map<String, dynamic> resolveData(
  IslandDesign design,
  Sources sources,
  Map<String, dynamic> serverData,
) {
  final out = <String, dynamic>{...serverData};
  for (final key in collectSourceKeys(design.raw)) {
    if (sources.containsKey(key)) out[key] = sources[key];
  }
  return out;
}

/// Every `{"src": k}` key referenced anywhere in a design tree.
Set<String> collectSourceKeys(dynamic node) {
  final keys = <String>{};
  _collect(node, keys);
  return keys;
}

void _collect(dynamic node, Set<String> keys) {
  if (node is Map) {
    final src = node['src'];
    if (src is String && src.isNotEmpty) keys.add(src);
    for (final v in node.values) {
      _collect(v, keys);
    }
  } else if (node is List) {
    for (final v in node) {
      _collect(v, keys);
    }
  }
}

/// Evaluate a condition expression against [sources]. A null/empty expr is
/// `true` (no condition = always). Unknown ops or missing operands are `false`
/// (fail safe — never spuriously activate a design).
bool evaluateCondition(Map<String, dynamic>? expr, Sources sources) {
  if (expr == null || expr.isEmpty) return true;
  final op = expr['op'];
  switch (op) {
    case 'and':
      final items = _items(expr);
      return items.every((e) => evaluateCondition(e, sources));
    case 'or':
      final items = _items(expr);
      return items.any((e) => evaluateCondition(e, sources));
    case 'not':
      final item = expr['item'];
      return !evaluateCondition(item is Map
          ? Map<String, dynamic>.from(item)
          : null, sources);
    case 'exists':
      return _operand(expr['a'], sources) != null;
    case 'eq':
      return _eq(_operand(expr['a'], sources), _operand(expr['b'], sources));
    case 'ne':
      return !_eq(_operand(expr['a'], sources), _operand(expr['b'], sources));
    case 'gt':
      return _cmp(_operand(expr['a'], sources),
              _operand(expr['b'], sources)) ==
          1;
    case 'lt':
      return _cmp(_operand(expr['a'], sources),
              _operand(expr['b'], sources)) ==
          -1;
    case 'between':
      final v = _num(_operand(expr['a'], sources));
      final lo = _num(expr['lo']);
      final hi = _num(expr['hi']);
      if (v == null || lo == null || hi == null) return false;
      return v >= lo && v <= hi;
    default:
      return false;
  }
}

List<Map<String, dynamic>> _items(Map<String, dynamic> expr) {
  final raw = expr['items'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
}

/// Resolve a condition operand: a binding (`{"$":k}` / `{"src":k}`) reads from
/// sources; anything else is a literal.
dynamic _operand(dynamic v, Sources sources) {
  if (v is Map) {
    final key = v['\$'] ?? v['src'];
    if (key is String) return sources[key];
    return null;
  }
  return v;
}

bool _eq(dynamic a, dynamic b) {
  if (a == null || b == null) return a == null && b == null;
  final na = _num(a), nb = _num(b);
  if (na != null && nb != null) return na == nb;
  return a.toString() == b.toString();
}

/// -1 / 0 / 1, or null if either side isn't numeric.
int? _cmp(dynamic a, dynamic b) {
  final na = _num(a), nb = _num(b);
  if (na == null || nb == null) return null;
  return na.compareTo(nb);
}

num? _num(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  if (v is bool) return v ? 1 : 0;
  return null;
}

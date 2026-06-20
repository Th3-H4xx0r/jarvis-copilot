// App-bundled "UI Example (max size)" Dynamic Island demo.
//
// The demo also exists server-side (island_store.DEMO_DESIGN), but bundling it in
// the app means an app rebuild alone shows the latest demo — no hermes redeploy
// needed. [injectBundledDemo] merges this OVER whatever the server returns, so
// the app always renders the current demo.
//
// It uses the `regions` container with a moderate album-art-style leading so the
// expanded island's top row + bottom stack to fill the ~144pt iOS cap (like
// Spotify/Apple Music) without overstuffing (which clips).

const Map<String, dynamic> islandDemoDesign = {
  'schema': 1,
  'id': 'demo',
  'version': 4,
  'name': 'UI Example (max size)',
  'icon': 'rectangle.on.rectangle.angled',
  'tint': '#0a84ff',
  'presentations': {
    'expanded': {
      'type': 'regions',
      'leading': {
        'type': 'image',
        'source': 'orb',
        'style': {'width': 52, 'height': 52},
      },
      'center': {
        'type': 'vstack',
        'spacing': 2,
        'children': [
          {
            'type': 'text',
            'value': 'Dynamic Island Demo',
            'style': {'size': 16, 'weight': 'bold'},
          },
          {
            'type': 'text',
            'value': 'Max-size UI example',
            'style': {'size': 13, 'color': '#8e8e93'},
          },
        ],
      },
      'trailing': {
        'type': 'symbol',
        'name': 'waveform',
        'style': {'size': 22, 'tint': '#0a84ff'},
      },
      'bottom': {
        'type': 'vstack',
        'spacing': 14,
        'style': {'minHeight': 86},
        'children': [
          {'type': 'progress', 'value': 0.7, 'tint': '#0a84ff'},
          {
            'type': 'hstack',
            'spacing': 40,
            'align': 'center',
            'children': [
              {'type': 'spacer'},
              {'type': 'symbol', 'name': 'backward.fill', 'style': {'size': 26}},
              {'type': 'symbol', 'name': 'pause.fill', 'style': {'size': 34}},
              {'type': 'symbol', 'name': 'forward.fill', 'style': {'size': 26}},
              {'type': 'spacer'},
            ],
          },
        ],
      },
    },
    'compactLeading': {'type': 'symbol', 'name': 'rectangle.on.rectangle.angled'},
    'compactTrailing': {'type': 'text', 'value': 'DEMO'},
    'minimal': {'type': 'symbol', 'name': 'rectangle.on.rectangle.angled'},
  },
};

const Map<String, dynamic> islandDemoCatalogEntry = {
  'id': 'demo',
  'name': 'UI Example (max size)',
  'icon': 'rectangle.on.rectangle.angled',
  'version': 4,
  'builtin': true,
  'enabled': false,
  'priority': 1,
};

/// Merge the bundled demo into a raw `GET /api/island/designs` payload (its
/// `designs` + `catalog` lists), replacing any server-provided `demo` so the app
/// always has the latest demo regardless of the hermes version.
void injectBundledDemo(Map<String, dynamic> raw) {
  final designs = (raw['designs'] is List)
      ? List<dynamic>.from(raw['designs'] as List)
      : <dynamic>[];
  designs.removeWhere((d) => d is Map && d['id'] == 'demo');
  designs.add(Map<String, dynamic>.from(islandDemoDesign));
  raw['designs'] = designs;

  final cat = (raw['catalog'] is List)
      ? List<dynamic>.from(raw['catalog'] as List)
      : <dynamic>[];
  // Preserve the user's enabled/priority overrides for the demo if present.
  final prior = cat.firstWhere(
      (c) => c is Map && c['id'] == 'demo', orElse: () => null);
  cat.removeWhere((c) => c is Map && c['id'] == 'demo');
  final entry = Map<String, dynamic>.from(islandDemoCatalogEntry);
  if (prior is Map) {
    for (final k in ['enabled', 'priority', 'conditions', 'schedule']) {
      if (prior.containsKey(k)) entry[k] = prior[k];
    }
  }
  cat.add(entry);
  raw['catalog'] = cat;
}

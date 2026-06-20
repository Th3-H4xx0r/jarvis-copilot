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
  'version': 5,
  'name': 'UI Example (max size)',
  'icon': 'rectangle.on.rectangle.angled',
  'tint': '#0a84ff',
  'presentations': {
    // Each region is LABELED so the expanded island visibly proves the
    // leading/trailing slots render BESIDE the camera cutout (not just below it).
    'expanded': {
      'type': 'regions',
      'leading': {
        'type': 'vstack',
        'spacing': 4,
        'style': {'align': 'leading'},
        'children': [
          {'type': 'badge', 'text': 'LEADING', 'color': '#34c759'},
          {'type': 'image', 'source': 'orb', 'style': {'width': 38, 'height': 38}},
        ],
      },
      'center': {
        'type': 'vstack',
        'spacing': 2,
        'children': [
          {
            'type': 'text',
            'value': 'Regions Demo',
            'style': {'size': 15, 'weight': 'bold'},
          },
          {
            'type': 'text',
            'value': 'beside + below the camera',
            'style': {'size': 11, 'color': '#8e8e93'},
          },
        ],
      },
      'trailing': {
        'type': 'vstack',
        'spacing': 4,
        'style': {'align': 'trailing'},
        'children': [
          {'type': 'badge', 'text': 'TRAILING', 'color': '#ff9f0a'},
          {'type': 'symbol', 'name': 'waveform', 'style': {'size': 22, 'tint': '#0a84ff'}},
        ],
      },
      'bottom': {
        'type': 'vstack',
        'spacing': 10,
        'style': {'minHeight': 82},
        'children': [
          {'type': 'badge', 'text': 'BOTTOM (full width)', 'color': '#0a84ff'},
          {'type': 'progress', 'value': 0.7, 'tint': '#0a84ff'},
          {
            'type': 'hstack',
            'spacing': 40,
            'align': 'center',
            'children': [
              {'type': 'spacer'},
              {'type': 'symbol', 'name': 'backward.fill', 'style': {'size': 24}},
              {'type': 'symbol', 'name': 'pause.fill', 'style': {'size': 32}},
              {'type': 'symbol', 'name': 'forward.fill', 'style': {'size': 24}},
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
  'version': 5,
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

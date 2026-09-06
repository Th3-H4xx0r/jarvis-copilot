import Foundation

/// App-bundled "UI Example (max size)" Dynamic Island demo.
///
/// The demo also exists server-side (`island_store.DEMO_DESIGN`), but bundling
/// it in the app means an app rebuild alone shows the latest demo — no hermes
/// redeploy needed. `injectBundledDemo` merges this OVER whatever the server
/// returns, so the app always renders the current demo.
///
/// It uses the `regions` container with a moderate album-art-style leading so
/// the expanded island's top row + bottom stack fill the ~144 pt iOS cap (like
/// Spotify / Apple Music) without overstuffing, which clips.
enum IslandDemo {
    static let design: JSONObject = [
        "schema": 1,
        "id": "demo",
        "version": 6,
        "name": "UI Example (max size)",
        "icon": "rectangle.on.rectangle.angled",
        "tint": "#0a84ff",
        "presentations": [
            // Each region is LABELED so the expanded island visibly proves the
            // leading/trailing slots render BESIDE the camera cutout, not just
            // below it.
            "expanded": [
                "type": "regions",
                "leading": [
                    "type": "vstack",
                    "spacing": 4,
                    "style": ["align": "leading"],
                    "children": [
                        ["type": "badge", "text": "LEADING", "color": "#34c759"],
                        ["type": "image", "source": "orb",
                         "style": ["width": 38, "height": 38]],
                    ],
                ],
                "center": [
                    "type": "vstack",
                    "spacing": 2,
                    "children": [
                        ["type": "text", "value": "Regions Demo",
                         "style": ["size": 15, "weight": "bold"]],
                        ["type": "text", "value": "beside + below the camera",
                         "style": ["size": 11, "color": "#8e8e93"]],
                    ],
                ],
                "trailing": [
                    "type": "vstack",
                    "spacing": 4,
                    "style": ["align": "trailing"],
                    "children": [
                        ["type": "badge", "text": "TRAILING", "color": "#ff9f0a"],
                        ["type": "symbol", "name": "waveform",
                         "style": ["size": 22, "tint": "#0a84ff"]],
                    ],
                ],
                "bottom": [
                    "type": "vstack",
                    "spacing": 10,
                    "style": ["minHeight": 82],
                    "children": [
                        ["type": "badge", "text": "BOTTOM (full width)", "color": "#0a84ff"],
                        ["type": "progress", "value": 0.7, "tint": "#0a84ff",
                         "tip": ["symbol": "airplane", "color": "#FFFFFF", "size": 13]],
                        ["type": "hstack",
                         "spacing": 40,
                         "align": "center",
                         "children": [
                            ["type": "spacer"],
                            ["type": "symbol", "name": "backward.fill", "style": ["size": 24]],
                            ["type": "symbol", "name": "pause.fill", "style": ["size": 32]],
                            ["type": "symbol", "name": "forward.fill", "style": ["size": 24]],
                            ["type": "spacer"],
                         ]],
                    ],
                ],
            ],
            "compactLeading": ["type": "symbol", "name": "rectangle.on.rectangle.angled"],
            "compactTrailing": ["type": "text", "value": "DEMO"],
            "minimal": ["type": "symbol", "name": "rectangle.on.rectangle.angled"],
        ],
    ]

    static let catalogEntry: JSONObject = [
        "id": "demo",
        "name": "UI Example (max size)",
        "icon": "rectangle.on.rectangle.angled",
        "version": 6,
        "builtin": true,
        "enabled": false,
        "priority": 1,
    ]

    /// Merge the bundled demo into a raw `GET /api/island/designs` payload (its
    /// `designs` + `catalog` lists), replacing any server-provided `demo` so the
    /// app always has the latest demo regardless of the hermes version. The
    /// user's `enabled` / `priority` / rule overrides for the demo survive.
    static func injectBundledDemo(_ raw: inout JSONObject) {
        var designs = MoreJSON.list(raw["designs"])
        designs.removeAll { ($0 as? JSONObject).map { MoreJSON.text($0["id"]) == "demo" } ?? false }
        designs.append(design)
        raw["designs"] = designs

        var catalog = MoreJSON.list(raw["catalog"])
        let prior = catalog.compactMap { $0 as? JSONObject }
            .first { MoreJSON.text($0["id"]) == "demo" }
        catalog.removeAll { ($0 as? JSONObject).map { MoreJSON.text($0["id"]) == "demo" } ?? false }
        var entry = catalogEntry
        if let prior {
            for key in ["enabled", "priority", "conditions", "schedule"] where prior[key] != nil {
                entry[key] = prior[key]
            }
        }
        catalog.append(entry)
        raw["catalog"] = catalog
    }
}

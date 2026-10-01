import SwiftUI
import WidgetKit

// The Dynamic Island's custom-design views: the shared renderer
// (Copilot/Shared/JarvisDesignRenderer.swift) inside a Live Activity.

/// Renders the cached design for `mode == "custom"`. Loads `design-<id>.json`
/// from the App Group; decodes; falls back to (app name + data.title) when the
/// design is missing/corrupt. Never crashes, never blank.
struct JCDesignView: View {
    let st: JarvisActivityAttributes.ContentState
    /// Which presentation node to render. `.lockScreen` uses lockScreen ?? expanded.
    var presentation: JCPresentation = .lockScreen

    enum JCPresentation { case lockScreen, compactLeading, compactTrailing, minimal }

    /// Compact / minimal slots are tiny — their fallback is just the orb.
    private var isCompact: Bool {
        switch presentation {
        case .compactLeading, .compactTrailing, .minimal: return true
        default: return false
        }
    }

    var body: some View {
        if let design = JCDesignCache.load(st.designId) {
            let ctx = JCBindingContext(dataJSON: st.data)
            let tint = jcParseColor(design.tint) ?? jcCodingColor("working")
            let renderer = JCDesignRenderer(tint: tint)
            let node = pickNode(design)
            content(renderer, node, ctx)
        } else {
            JCDesignFallback(st: st, compact: isCompact)
        }
    }

    @ViewBuilder
    private func content(_ r: JCDesignRenderer, _ node: JCNode?, _ ctx: JCBindingContext) -> some View {
        if node == nil {
            JCDesignFallback(st: st, compact: isCompact)
        } else {
            switch presentation {
            case .lockScreen:
                r.render(node, ctx)
                    .padding(.horizontal, 16).padding(.vertical, 13)
            default:
                r.render(node, ctx)
            }
        }
    }

    private func pickNode(_ d: JCDesign) -> JCNode? {
        switch presentation {
        case .lockScreen: return d.presentations.lockScreen ?? d.presentations.expanded
        case .compactLeading: return d.presentations.compactLeading
        case .compactTrailing: return d.presentations.compactTrailing
        case .minimal: return d.presentations.minimal
        }
    }
}

/// Fallback when the design is missing/corrupt: the app name + an optional
/// `data.title` so the activity is never blank and never crashes.
struct JCDesignFallback: View {
    let st: JarvisActivityAttributes.ContentState
    var compact: Bool = false
    private var title: String? {
        let ctx = JCBindingContext(dataJSON: st.data)
        return ctx.data["title"]?.asString
    }
    var body: some View {
        if compact {
            JarvisOrb(state: "idle", size: 22)
        } else {
            HStack(spacing: 10) {
                JarvisOrb(state: "idle", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    if let t = title, !t.isEmpty {
                        Text(t).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

import SwiftUI

/// Where a dashboard card leads.
enum ChatDashboardDestination: Equatable {
    case wearables, devices, coding, usage
}

/// The status cards a new chat opens on: wearables, paired devices, coding
/// sessions and usage, two by two. Every card is a button into the screen
/// that owns its data.
struct ChatDashboard: View {
    let store: ChatDashboardStore
    var compact = false
    let onOpen: (ChatDashboardDestination) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                  spacing: 10) {
            wearablesCard
            devicesCard
            codingCard
            usageCard
        }
    }

    // MARK: Cards

    private var wearablesCard: some View {
        let w = store.wearables
        return DashboardCard(compact: compact,
                             value: w.total == 0 ? "None paired" : "\(w.connected) of \(w.total)",
                             caption: w.total == 0 ? "Wearables" : "Wearables connected",
                             accessibility: w.total == 0 ? "No wearables paired"
                                 : "\(w.connected) of \(w.total) wearables connected",
                             action: { onOpen(.wearables) }) {
            StackedAvatars(items: w.kinds.map { kind in
                AvatarItem(image: WearableArt.image(for: kind), symbol: WearableArt.symbol(for: kind))
            }, emptySymbol: "applewatch.radiowaves.left.and.right")
        }
    }

    private var devicesCard: some View {
        let card = store.devices
        let value: String
        let caption: String
        var kinds: [String] = []
        switch card {
        case .loading: value = "—"; caption = "Jarvis devices"
        case .unavailable: value = "Offline"; caption = "Jarvis devices"
        case .ready(let d):
            value = d.total == 0 ? "None paired" : "\(d.online) of \(d.total)"
            caption = d.total == 0 ? "Jarvis devices" : "Devices online"
            kinds = d.iconKinds
        }
        return DashboardCard(compact: compact, value: value, caption: caption,
                             loading: card == .loading,
                             accessibility: "\(caption): \(value)",
                             action: { onOpen(.devices) }) {
            StackedAvatars(items: kinds.map { AvatarItem(image: nil, symbol: Self.deviceSymbol($0)) },
                           emptySymbol: "laptopcomputer.and.iphone")
        }
    }

    private var codingCard: some View {
        let card = store.coding
        let value: String
        let caption: String
        var waiting = 0
        switch card {
        case .loading: value = "—"; caption = "Coding sessions"
        case .unavailable: value = "Offline"; caption = "Coding sessions"
        case .ready(let c):
            value = c.running == 0 ? "None running" : "\(c.running) running"
            waiting = c.waiting
            caption = c.waiting > 0 ? "\(c.waiting) waiting on you" : "Coding sessions"
        }
        return DashboardCard(compact: compact, value: value, caption: caption,
                             captionTint: waiting > 0 ? JcTheme.amber : JcTheme.muted,
                             loading: card == .loading,
                             accessibility: "\(value), \(caption)",
                             action: { onOpen(.coding) }) {
            SymbolBadge(symbol: "terminal", dot: waiting > 0 ? JcTheme.amber : nil)
        }
    }

    private var usageCard: some View {
        let card = store.usage
        let value: String
        let caption: String
        var fraction: Double?
        switch card {
        case .loading: value = "—"; caption = "Usage"
        case .unavailable: value = "—"; caption = "No usage data"
        case .ready(let u):
            value = "\(Int(u.usedPercent.rounded()))%"
            caption = "\(u.provider) · \(u.window)"
            fraction = u.usedPercent / 100
        }
        return DashboardCard(compact: compact, value: value, caption: caption,
                             loading: card == .loading,
                             accessibility: "Usage \(value), \(caption)",
                             action: { onOpen(.usage) }) {
            UsageRing(fraction: fraction)
        }
    }

    static func deviceSymbol(_ kind: String) -> String {
        switch kind {
        case "watch":   return "applewatch"
        case "tablet":  return "ipad"
        case "phone":   return "iphone"
        case "laptop":  return "laptopcomputer"
        case "web":     return "globe"
        default:        return "desktopcomputer"
        }
    }
}

// MARK: - Pieces

/// One card: artwork top-left, a chevron top-right, the number and what it
/// counts underneath.
private struct DashboardCard<Art: View>: View {
    var compact: Bool
    let value: String
    let caption: String
    var captionTint: Color = JcTheme.muted
    var loading = false
    let accessibility: String
    let action: () -> Void
    @ViewBuilder let art: () -> Art

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack(alignment: .top) {
                    art()
                    Spacer(minLength: 4)
                    JcIcon("chevron.right", size: 11, weight: .semibold)
                        .foregroundStyle(JcTheme.muted.opacity(0.7))
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .redacted(reason: loading ? .placeholder : [])
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(captionTint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 12 : 14)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.065), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
    }
}

struct AvatarItem {
    let image: UIImage?
    let symbol: String
}

/// Overlapping circles, like a group of contacts: up to three, then "+N".
private struct StackedAvatars: View {
    let items: [AvatarItem]
    let emptySymbol: String

    private static let side: CGFloat = 34
    private static let overlap: CGFloat = 12
    private static let maxShown = 3

    var body: some View {
        let shown = Array(items.prefix(Self.maxShown))
        let extra = items.count - shown.count
        HStack(spacing: -Self.overlap) {
            if shown.isEmpty {
                circle { symbol(emptySymbol) }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                // The rendered wearables are matte black: on the symbol circles'
                // near-black they were silhouettes of nothing.
                circle(fill: item.image == nil ? Color(jcHex: 0x151A22) : Color(jcHex: 0x3A4250)) {
                    if let image = item.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.25)
                    } else {
                        symbol(item.symbol)
                    }
                }
                .zIndex(Double(shown.count - index))
            }
            if extra > 0 {
                circle {
                    Text("+\(extra)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        JcIcon(name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(JcTheme.cyan)
    }

    private func circle<Content: View>(fill: Color = Color(jcHex: 0x151A22),
                                       @ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }
            .frame(width: Self.side, height: Self.side)
            .background(fill, in: Circle())
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color(jcHex: 0x0A0C12), lineWidth: 2))
    }
}

private struct SymbolBadge: View {
    let symbol: String
    var dot: Color?

    var body: some View {
        JcIcon(symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(JcTheme.cyan)
            .frame(width: 34, height: 34)
            .background(Color(jcHex: 0x151A22), in: Circle())
            .overlay(alignment: .topTrailing) {
                if let dot {
                    Circle().fill(dot)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(jcHex: 0x0A0C12), lineWidth: 2))
                        .offset(x: 1, y: -1)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A small gauge for the usage card; empty track while nothing is known.
private struct UsageRing: View {
    let fraction: Double?

    private var tint: Color {
        guard let fraction else { return JcTheme.muted }
        if fraction >= 0.9 { return JcTheme.danger }
        if fraction >= 0.75 { return JcTheme.amber }
        return JcTheme.cyan
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(fraction ?? 0, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 30, height: 30)
        .padding(2)
        .accessibilityHidden(true)
    }
}

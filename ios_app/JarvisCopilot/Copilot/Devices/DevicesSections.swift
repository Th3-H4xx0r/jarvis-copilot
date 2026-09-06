import SwiftUI

// MARK: - Server summary

/// The state of the box behind the devices, as one quiet card: a status line, a
/// three-metric strip with thin bars, and the knowledge base as a footnote.
///
/// It replaces five coloured pills. The pills were all the same shape and weight
/// as each other and as the skill chips below them, so nothing on the screen was
/// more important than anything else; a bar carries "how full" far better than a
/// capsule with a number in it, and only turns colour when a number is actually
/// worth reacting to.
struct DevicesHealthStrip: View {
    let health: SystemHealth
    let wiki: WikiStatus

    private var hasHealth: Bool { InsightsUI.healthIsAvailable(health) }
    private var showsWiki: Bool { !wiki.status.isEmpty }

    private var metrics: [(label: String, percent: Double)] {
        var out: [(String, Double)] = []
        if let cpu = health.cpuPercent { out.append(("CPU", cpu)) }
        if let memory = health.memoryPercent { out.append(("Memory", memory)) }
        if let disk = health.diskPercent { out.append(("Disk", disk)) }
        return out
    }

    var body: some View {
        if hasHealth || showsWiki {
            GlassGroup(blur: false) {
                statusRow
                if hasHealth {
                    DevicesHairline()
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(metrics, id: \.label) { metric in
                            DevicesMetricColumn(label: metric.label, percent: metric.percent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                }
                if showsWiki {
                    DevicesHairline()
                    wikiRow
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hasHealth ? JcTheme.success : JcTheme.muted.opacity(0.6))
                .frame(width: 6, height: 6)
            Text("Server")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        guard hasHealth else { return health.failed ? "Unreachable" : "Not reporting" }
        return health.status == "partial" ? "Partial" : "Live"
    }

    private var wikiRow: some View {
        let badge = InsightsUI.wikiBadge(wiki)
        return HStack(spacing: 8) {
            Text("Knowledge base")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.text.opacity(0.85))
            Spacer(minLength: 8)
            Text(badge.label)
                .font(.system(size: 13))
                // Only a real error earns colour; "Unavailable" is a fact, not an
                // alarm, and a red pill for it was most of the old noise.
                .foregroundStyle(badge.tone == .danger ? JcTheme.danger : JcTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One health metric: a small label, the percentage, and a 3pt bar.
struct DevicesMetricColumn: View {
    let label: String
    /// 0…100.
    let percent: Double

    /// Grey until it matters. `InsightsUI.metricTone` starts colouring at 70%,
    /// which on a normal server means three coloured bars at all times; here the
    /// bar only speaks up when the number is genuinely worth a look.
    private var tint: Color {
        if percent >= 90 { return JcTheme.danger }
        if percent >= 75 { return JcTheme.amber }
        return JcTheme.text.opacity(0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(JcTheme.muted)
            Text(InsightsUI.metricPercentText(percent))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * min(max(percent / 100, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One device

/// A paired device as an inset-list group: an identity row, then the granted
/// skills behind a disclosure.
///
/// What changed from the first cut, and why:
/// * the 40pt tinted circle became a plain glyph — the icon is a hint, not the
///   subject of the row;
/// * "Online", the relative time and the platform collapsed into one muted meta
///   line under the name, so the eye reads name → detail rather than five
///   competing colours;
/// * Log out / Revoke moved into a menu. A destructive button repeated on every
///   card makes a page look dangerous and, worse, makes revoking a device the
///   easiest thing to do on it.
struct DeviceServerCard: View {
    let device: Device
    let skills: [DeviceSkill]
    /// Marks the record for the phone this app is running on.
    let isThisDevice: Bool
    let onLogout: () -> Void
    let onRevoke: () -> Void

    @State private var expanded: Bool

    init(device: Device,
         skills: [DeviceSkill],
         isThisDevice: Bool = false,
         expanded: Bool = false,
         onLogout: @escaping () -> Void,
         onRevoke: @escaping () -> Void) {
        self.device = device
        self.skills = skills
        self.isThisDevice = isThisDevice
        self.onLogout = onLogout
        self.onRevoke = onRevoke
        _expanded = State(initialValue: expanded)
    }

    private var groups: [DeviceSkillGroup] { DevicesSkillText.groups(skills) }

    var body: some View {
        GlassGroup(blur: false) {
            identityRow
            DevicesHairline()
            if skills.isEmpty {
                // Nothing to disclose — a chevron that opens an apology is worse
                // than no chevron.
                summaryLabel
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else {
                disclosureRow
                if expanded { skillList }
            }
        }
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSectionSymbol(device))
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(JcTheme.text.opacity(device.online ? 0.9 : 0.55))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    if isThisDevice { DevicesTag(text: "This device") }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.online ? JcTheme.success : JcTheme.muted.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(DevicesKind.metaLine(for: device))
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actionMenu
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // The same two actions on a long press, for anyone who reaches for the
        // row rather than the glyph.
        .contextMenu {
            Button("Log out", systemImage: "rectangle.portrait.and.arrow.right", action: onLogout)
            Button("Revoke", systemImage: "trash", role: .destructive, action: onRevoke)
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("Log out", systemImage: "rectangle.portrait.and.arrow.right", action: onLogout)
            Button("Revoke", systemImage: "trash", role: .destructive, action: onRevoke)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(device.displayName)")
    }

    // MARK: Skills

    private var summaryLabel: some View {
        Text(DevicesSkillText.grantedSummary(skills.count))
            .font(.system(size: 13))
            .foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosureRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                summaryLabel
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.muted.opacity(0.8))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DevicesSkillText.grantedSummary(skills.count))
        .accessibilityHint(expanded ? "Hide the skill list" : "Show the skill list")
    }

    private var skillList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(JcTheme.muted.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                ForEach(group.skills) { skill in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DevicesSkillText.title(for: skill))
                            .font(.system(size: 13.5))
                            .foregroundStyle(JcTheme.text.opacity(0.92))
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.system(size: 11.5))
                                .foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
            }
            let detail = DevicesKind.detailLine(for: device)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, 13)
    }
}

// MARK: - Whole-screen states

/// Nothing paired yet. A quiet card that says what the screen is for, with the
/// pair button right under it doing the asking.
struct DevicesEmptyState: View {
    var body: some View {
        GlassCard(padding: 20, blur: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No devices paired")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text("Devices you pair with this server appear here, with the "
                   + "skills each one is allowed to run.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The list endpoint failed and there is nothing to show. Mirrors the Flutter
/// page's error card — glyph, the server's own words, one retry.
struct DevicesErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack {
            GlassCard(padding: 22, blur: false) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(JcTheme.muted)
                    Text("Can't load your devices")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    GlassButton(title: "Try again", symbol: "arrow.clockwise",
                                ghost: true, action: onRetry)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small parts

/// A hairline between rows of a `GlassGroup`, full-bleed (the rows here have no
/// leading icon column to indent past).
struct DevicesHairline: View {
    var body: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
    }
}

/// A colourless capsule label — "This device". Deliberately not a `StatusPill`:
/// it is a note about which row you are looking at, not a status, and giving it a
/// colour would put it in competition with the online dot beside it.
struct DevicesTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(JcTheme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .fixedSize()
    }
}

/// SF Symbol for a server device record.
///
/// Reuses `deviceIconKind` (the Live Activity's mapping, ported from
/// `voice/device_icon.dart`) so a device shows the SAME glyph here and on the
/// Lock Screen. `Device` normalises the record's `kind`/`platform` and
/// `name`/`label` fields, so they're fed back in under the names that helper
/// expects.
func deviceSectionSymbol(_ device: Device) -> String {
    let kind = deviceIconKind(["kind": device.platform, "name": device.label])
    switch kind {
    case "watch":   return "applewatch"
    case "tablet":  return "ipad"
    case "phone":   return "iphone"
    case "laptop":  return "laptopcomputer"
    case "web":     return "globe"
    default:        return "desktopcomputer"
    }
}

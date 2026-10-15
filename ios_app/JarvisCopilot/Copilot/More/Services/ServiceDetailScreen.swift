import SwiftUI

/// One service up close: its figures, longer lists, links, and the few safe
/// actions the server offers on items (redeploy, re-run CI, retry a workflow…).
/// Every action asks for Face ID first; one that can't be undone asks you to
/// confirm too, and the result comes back as a banner.
struct ServiceDetailScreen: View {
    let serviceID: String
    var store: ServicesStore = .shared

    private var detail: ServiceDetail? { store.details[serviceID] }
    private var snapshot: ServiceSnapshot? { store.snapshot(serviceID) }
    private var loadError: String? { store.detailErrors[serviceID] }

    private var title: String {
        detail?.displayName ?? snapshot?.displayName ?? serviceID.capitalized
    }

    /// The detail's lists; while it's loading (or couldn't be read) the pill's
    /// own latest items, without actions.
    private var sections: [ServiceSection] {
        if let detail, !detail.sections.isEmpty { return detail.sections }
        return snapshot?.sections ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let snapshot { summary(snapshot) }
                if let github = snapshot?.github { GitHubActivityCard(activity: github) }
                if let last = detail?.lastAction { lastAction(last) }
                if let error = detail?.error ?? (detail == nil ? loadError : nil) { problem(error) }
                if let stats = detail?.stats, !stats.isEmpty { statsGrid(stats) }
                ForEach(sections) { section in
                    ServiceSectionView(section: section, serviceID: serviceID, store: store)
                }
                if detail == nil && loadError == nil {
                    ProgressView()
                        .tint(JcTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .refreshable { await store.loadDetail(serviceID) }
        .jcScreen(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ServicesRoute.keys(.services(serviceID))) {
                    JcIcon("key", size: 17)
                }
                .accessibilityLabel("\(title) key and settings")
            }
        }
        .task { await store.loadDetail(serviceID) }
        .servicesVisibility { store.setVisible($0, feed: .services, owner: "service-detail") }
        .confirmationDialog(store.pendingConfirmation?.question ?? "Are you sure?",
                            isPresented: confirming, titleVisibility: .visible,
                            presenting: store.pendingConfirmation) { question in
            Button(question.action.title, role: question.action.destructive ? .destructive : nil) {
                Task { await store.confirm(question) }
            }
            Button("Cancel", role: .cancel) { store.cancelPending() }
        }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3.5)
    }

    private var confirming: Binding<Bool> {
        Binding(get: { store.pendingConfirmation?.serviceID == serviceID },
                set: { if !$0 { store.cancelPending() } })
    }

    // MARK: pieces

    private func summary(_ snapshot: ServiceSnapshot) -> some View {
        let color = ServicesStyle.color(snapshot.tone)
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                if !snapshot.headline.isEmpty {
                    Text(snapshot.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                }
                if !snapshot.reason.isEmpty {
                    Text(snapshot.reason)
                        .font(.system(size: 13))
                        .foregroundStyle(snapshot.tone == .error || snapshot.tone == .warning ? color : JcTheme.muted)
                }
                if let updated = snapshot.updatedAt {
                    Text("Checked \(ServicesFormat.agoPhrase(updated))")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private func lastAction(_ result: ServiceActionResult) -> some View {
        let tint = result.ok ? JcTheme.success : JcTheme.danger
        return HStack(alignment: .top, spacing: 10) {
            JcIcon(result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 14)
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.line)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                if let at = result.at {
                    Text(ServicesFormat.ago(at) == "now" ? "Just now" : ServicesFormat.agoPhrase(at))
                        .font(.system(size: 11))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                JcIcon("exclamationmark.circle", size: 14).foregroundStyle(JcTheme.danger).padding(.top, 1)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.text)
            }
            NavigationLink(value: ServicesRoute.keys(.services(serviceID))) {
                Text("Check the key")
            }
            .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.35), lineWidth: 1))
    }

    private func statsGrid(_ stats: [ServiceStat]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 4) {
                    Text(stat.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(stat.tone == .idle ? JcTheme.text : ServicesStyle.color(stat.tone))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A titled list of items, as the service grouped them.
private struct ServiceSectionView: View {
    let section: ServiceSection
    let serviceID: String
    let store: ServicesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !section.title.isEmpty { SectionHeader(section.title) }
            if section.items.isEmpty {
                Text("Nothing here right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 4)
            } else {
                GlassGroup {
                    ForEach(section.items) { item in
                        ServiceItemRow(item: item, serviceID: serviceID, store: store)
                        if item.id != section.items.last?.id {
                            Divider().overlay(JcTheme.glassBorder).padding(.leading, 32)
                        }
                    }
                }
            }
            if let footer = section.footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One item: what it is, its figure and tag, a link out, and its actions.
private struct ServiceItemRow: View {
    let item: ServiceItem
    let serviceID: String
    let store: ServicesStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = item.url {
                Button { openURL(url) } label: { content(link: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens it in the browser")
            } else {
                content(link: false)
            }
            if !item.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.actions) { action in actionButton(action) }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func content(link: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(ServicesStyle.color(item.tone))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(2)
                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(JcTheme.text.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.08), in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let value = item.value {
                        Text(value)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.tone == .idle ? JcTheme.text : ServicesStyle.color(item.tone))
                            .lineLimit(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if let date = item.date {
                        Text(ServicesFormat.ago(date))
                            .font(.system(size: 11))
                            .foregroundStyle(JcTheme.muted)
                    }
                    if link {
                        JcIcon("arrow.up.right", size: 10).foregroundStyle(JcTheme.muted)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func actionButton(_ action: ServiceAction) -> some View {
        let busy = store.isRunning(action)
        return Button {
            Task { await store.tap(action, service: serviceID) }
        } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini).tint(action.destructive ? JcTheme.danger : JcTheme.accent)
                } else if !action.symbol.isEmpty {
                    JcIcon(action.symbol, size: 12)
                }
                Text(action.title).lineLimit(1)
            }
        }
        .buttonStyle(.jcGlass(tint: action.destructive ? JcTheme.danger : JcTheme.accent, compact: true))
        .disabled(busy)
        .accessibilityHint("Asks for Face ID first")
    }
}

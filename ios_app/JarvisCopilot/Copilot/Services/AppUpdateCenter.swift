import SwiftUI
import UIKit

/// A newer build of this app the server is offering (`/api/app-updates/latest`).
struct AppUpdateOffer: Equatable {
    let build: Int
    let version: String
    let notes: String
    let installURL: URL
    /// Bytes to download; 0 when the server didn't say.
    var size: Int64 = 0

    /// The link's token, which names it to `/api/app-updates/install-status`: the
    /// manifest URL inside `itms-services://?…&url=…/ota/m/<token>.plist`.
    var installToken: String? {
        guard let inner = URLComponents(url: installURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let name = URL(string: inner)?.lastPathComponent, name.hasSuffix(".plist") else { return nil }
        return String(name.dropLast(".plist".count))
    }

    /// The server's answer, or nil when it offers nothing newer than `installed`.
    static func decode(_ obj: [String: Any], installed: Int) -> AppUpdateOffer? {
        guard obj["available"] as? Bool == true,
              let build = (obj["build"] as? NSNumber)?.intValue, build > installed,
              let link = obj["install_url"] as? String, let url = URL(string: link), url.scheme != nil
        else { return nil }
        return AppUpdateOffer(build: build, version: obj["version"] as? String ?? "",
                              notes: (obj["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              installURL: url,
                              size: (obj["size"] as? NSNumber)?.int64Value ?? 0)
    }
}

enum AppUpdateRules {
    /// The server's "Jarvis update ready" banner (its data rides in the `jarviscopilot` envelope).
    static func isUpdatePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let envelope = userInfo[NotificationAction.envelopeKey] as? [String: Any] ?? [:]
        return (envelope["kind"] ?? envelope["type"]) as? String == "app_update"
    }

    /// Up only in front, never over a live voice session, and not for the build the user
    /// said Later to (until the app is opened again).
    static func shouldShow(_ offer: AppUpdateOffer?, foreground: Bool, voiceActive: Bool,
                           laterBuild: Int?) -> Bool {
        guard let offer, foreground, !voiceActive else { return false }
        return offer.build != laterBuild
    }
}

/// The "Update available" pop-up. Claude publishes a build to the server
/// (`scripts/publish-app-update.sh`); an open app hears it on the bridge topic
/// `app_update` and asks the server, a closed one gets a banner whose tap opens
/// the app onto this card. Install now hands iOS a short-lived `itms-services`
/// link, iOS confirms, closes Jarvis and installs over it keeping its data.
@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    @Published private(set) var offer: AppUpdateOffer?
    @Published private(set) var installing = false
    @Published private(set) var error: String?
    private var foreground = false
    private var wasBackgrounded = true
    private var laterBuild: Int?
    private let window = OverlayWindow()
    private var started = false
    private var installWatch: Task<Void, Never>?

    /// This build's number (`CFBundleVersion`, stamped at build time; `1` = unstamped).
    static var installedBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    func start() {
        guard !started else { return }
        started = true
        BridgeTopics.shared.want("app_update", owner: "app-update")
        // In the background the card can't show, and coming forward checks anyway.
        BridgeTopics.shared.on("app_update") { [weak self] data in
            guard let self, self.foreground, data["platform"] as? String ?? "ios" == "ios" else { return }
            Task { await self.check() }
        }
        BridgeTopics.shared.onResync { [weak self] in
            guard let self, self.foreground else { return }
            Task { await self.check() }
        }
        followVoice()
    }

    /// A voice session starting (Action button, a control, the watch) takes the card
    /// down at once; it comes back when the session ends.
    private func followVoice() {
        withObservationTracking { _ = VoiceStore.shared.isActive } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.followVoice()
            }
        }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            foreground = true
            // A fresh open brings back an offer the user put off with Later.
            if wasBackgrounded { laterBuild = nil }
            wasBackgrounded = false
            Task { await check() }
        case .background:
            foreground = false
            wasBackgrounded = true
            update()
        default:
            break
        }
    }

    /// The banner was tapped: show the card even if Later hid it.
    func openFromNotification() {
        laterBuild = nil
        Task { await check() }
    }

    /// Ask the server whether there's something newer than this build. False when it
    /// couldn't be asked (the offer in hand is then left as it was).
    @discardableResult
    func check() async -> Bool {
        guard JarvisAPI.shared.isPaired else { return false }
        var asked = false
        do {
            let obj = try await JarvisAPI.shared.get(
                "/api/app-updates/latest",
                query: ["platform": "ios", "build": String(Self.installedBuild)], timeout: 20).object()
            offer = AppUpdateOffer.decode(obj, installed: Self.installedBuild)
            asked = true
        } catch {
            JcLog.dropped(JcLog.core, "app update check", error)
        }
        update()
        return asked
    }

    func later() {
        laterBuild = offer?.build
        update()
    }

    func install() async {
        guard !installing else { return }
        installing = true
        error = nil
        defer { installing = false }
        // The link in hand may be minutes old and links expire, so only a fresh one goes.
        guard await check() else {
            error = "Couldn't reach Jarvis to start the install. Try again."
            return
        }
        guard let offer else { return }
        // iOS takes it from here: its own confirm, then it closes Jarvis to install.
        // The card stays, so a cancelled confirm can be tried again.
        if await UIApplication.shared.open(offer.installURL) {
            if let token = offer.installToken { quitOnceInstalling(token) }
        } else {
            error = "iOS couldn't open the install link."
        }
    }

    /// iOS won't install over a Jarvis that's still running, and it never closes it
    /// itself. It fetches the package only after the user taps Install on its confirm,
    /// so once the server has seen that fetch Jarvis steps out to the Home Screen
    /// (where the icon shows the install) and quits. A Cancel never fetches, so the
    /// card just stays up.
    private func quitOnceInstalling(_ token: String) {
        installWatch?.cancel()
        installWatch = Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let answer = try? await JarvisAPI.shared.get(
                    "/api/app-updates/install-status", query: ["token": token], timeout: 5).object()
                if answer?["started"] as? Bool == true {
                    self?.quitForInstall()
                    return
                }
            }
        }
    }

    private func quitForInstall() {
        let app = UIApplication.shared
        let task = app.beginBackgroundTask(withName: "app-update-quit")
        // Home first so it reads as stepping aside, not a crash; then gone.
        UIControl().sendAction(#selector(URLSessionTask.suspend), to: app, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            _ = task
            exit(0)
        }
    }

    private func update() {
        let wanted = AppUpdateRules.shouldShow(offer, foreground: foreground,
                                               voiceActive: VoiceStore.shared.isActive,
                                               laterBuild: laterBuild)
        if wanted { window.show { AppUpdateCard(center: self) } } else { window.hide() }
    }
}

struct AppUpdateCard: View {
    @ObservedObject var center: AppUpdateCenter

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { center.later() }
            if let offer = center.offer {
                AppUpdateSheet(offer: offer, installing: center.installing, error: center.error,
                               onInstall: { Task { await center.install() } },
                               onLater: { center.later() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.12), value: center.offer)
    }
}

/// The card itself, like the system's App Store / AirPods sheets: the app's own icon,
/// what's new as a list, one prominent action. Separate from `AppUpdateCard` so it
/// can be drawn without a live center.
struct AppUpdateSheet: View {
    let offer: AppUpdateOffer
    var installing = false
    var error: String?
    var onInstall: () -> Void = {}
    var onLater: () -> Void = {}

    private let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            if !items.isEmpty { whatsNew.padding(.top, 22) }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
            actions.padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .frame(maxWidth: 460)
        // The app's card: surface on black, one hairline.
        .background(ZStack { JcTheme.bg; JcTheme.glassFill }.clipShape(shape))
        .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(spacing: 0) {
            AppIconImage()
                .frame(width: 72, height: 72)
            HStack(spacing: 7) {
                Circle().fill(JcTheme.accent).frame(width: 6, height: 6)
                Text("Update available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.text.opacity(0.85))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: Capsule())
            .padding(.top, 18)
            Text(offer.version.isEmpty ? "Jarvis" : "Jarvis \(offer.version)")
                .font(.system(size: 27, weight: .medium))
                .tracking(-0.6)
                .foregroundStyle(JcTheme.text)
                .padding(.top, 12)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Build 263022206 · 67.6 MB" — the build as digits, never "263,022,206".
    private var subtitle: String {
        var parts = ["Build \(String(offer.build))"]
        if offer.size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// The notes one line per item, with the "•" / "-" the publisher typed taken off.
    private var items: [String] {
        offer.notes.split(whereSeparator: \.isNewline).map {
            var line = $0.trimmingCharacters(in: .whitespaces)
            if let first = line.first, "•-*".contains(first) { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("What\u{2019}s new", first: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(JcTheme.muted)
                                .frame(width: 5, height: 5)
                                // Centred on the first line's x-height.
                                .alignmentGuide(.firstTextBaseline) { d in d.height + 4 }
                            Text(item)
                                .font(.system(size: 15))
                                .foregroundStyle(JcTheme.text.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .padding(JcUnified.cardPadding)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 1))
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            GradientButton(installing ? "Installing…" : "Install now", symbol: "arrow.down.circle",
                           busy: installing, full: true, action: onInstall)
            Button("Not now", action: onLater)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
    }
}

/// This app's own icon, read from its bundle; a plain glyph if the system won't hand it over.
struct AppIconImage: View {
    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(JcAccent.onColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(JcTheme.accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13.5, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    static let icon: UIImage? = {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let name = primary?["CFBundleIconName"] as? String, let image = UIImage(named: name) { return image }
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        return files.reversed().lazy.compactMap { UIImage(named: $0) }.first
    }()
}

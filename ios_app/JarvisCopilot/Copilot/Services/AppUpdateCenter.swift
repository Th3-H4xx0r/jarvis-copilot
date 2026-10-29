import SwiftUI
import UIKit

/// A newer build of this app the server is offering (`/api/app-updates/latest`).
struct AppUpdateOffer: Equatable {
    let build: Int
    let version: String
    let notes: String
    let installURL: URL

    /// The server's answer, or nil when it offers nothing newer than `installed`.
    static func decode(_ obj: [String: Any], installed: Int) -> AppUpdateOffer? {
        guard obj["available"] as? Bool == true,
              let build = (obj["build"] as? NSNumber)?.intValue, build > installed,
              let link = obj["install_url"] as? String, let url = URL(string: link), url.scheme != nil
        else { return nil }
        return AppUpdateOffer(build: build, version: obj["version"] as? String ?? "",
                              notes: (obj["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              installURL: url)
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
    private var window: UIWindow?
    private var started = false

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
        if !(await UIApplication.shared.open(offer.installURL)) {
            error = "iOS couldn't open the install link."
        }
    }

    private func update() {
        let wanted = AppUpdateRules.shouldShow(offer, foreground: foreground,
                                               voiceActive: VoiceStore.shared.isActive,
                                               laterBuild: laterBuild)
        if wanted { present() } else { dismiss() }
    }

    // MARK: Window

    private func present() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: AppUpdateCard(center: self))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        made.backgroundColor = .clear
        made.rootViewController = host
        made.isHidden = false
        window = made
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    private func dismiss() {
        window?.isHidden = true
        window = nil
    }
}

struct AppUpdateCard: View {
    @ObservedObject var center: AppUpdateCenter

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { center.later() }
            if let offer = center.offer {
                card(offer)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: center.offer)
    }

    private func card(_ offer: AppUpdateOffer) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .padding(.bottom, 10)
            Text("Update available")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(offer.version.isEmpty ? "Build \(offer.build)" : "Version \(offer.version) · build \(offer.build)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            if !offer.notes.isEmpty {
                ScrollView {
                    Text(offer.notes)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            }
            if let error = center.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(JcTheme.danger)
                    .padding(.top, 10)
            }
            VStack(spacing: 6) {
                Button { Task { await center.install() } } label: {
                    HStack(spacing: 8) {
                        if center.installing { ProgressView() } else { Text("Install now") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.jcGlass(full: true))
                .disabled(center.installing)
                Button("Later") { center.later() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: 420)
        .background(JcTheme.bg, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.accent.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
    }
}

import Foundation
import Observation

/// Page state for the Devices screen: paired devices with their skill ACL, plus
/// the server-health / wiki strip the same screen shows.
///
/// `health` and `wiki` come from `InsightsAPI` (they're the same
/// `/api/system/health` and `/api/wiki/status` endpoints the Insights page
/// uses — one parser, two screens).
@Observable
@MainActor
final class DevicesStore {
    private let api: DevicesAPI
    private let insights: InsightsAPI
    private let task = TaskHandle()

    private(set) var devices: [Device] = []
    /// Every grantable skill, for rendering a device's ACL against the full set.
    private(set) var catalogue: [DeviceSkill] = []
    private(set) var health = SystemHealth()
    private(set) var wiki = WikiStatus()

    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    var toast: String?

    init(api: DevicesAPI = DevicesAPI(), insights: InsightsAPI = InsightsAPI()) {
        self.api = api
        self.insights = insights
    }

    deinit { task.cancel() }

    var isEmpty: Bool { hasLoaded && devices.isEmpty }
    var emptyText: String { "No devices found" }

    /// The skills one device is granted, expressed against the full catalogue so
    /// the UI can show what it *doesn't* have too. Falls back to the device's own
    /// list when the catalogue hasn't loaded.
    func skills(for device: Device) -> [DeviceSkill] {
        guard !catalogue.isEmpty else { return device.skills }
        let granted = Set(device.skills.filter(\.allowed).map(\.name))
        return catalogue.map { skill in
            var row = skill
            row.allowed = granted.contains(skill.name)
            return row
        }
    }

    func grantedSkills(for device: Device) -> [DeviceSkill] {
        device.skills.filter(\.allowed)
    }

    func load() {
        isLoading = true
        errorMessage = nil
        task.replace(Task { [weak self] in await self?.refresh() })
    }

    /// The device list is the only required fetch; the catalogue and the health
    /// strip degrade to empty on their own.
    func refresh() async {
        async let catalogueLoad = api.allSkills()
        async let healthLoad = insights.systemHealth()
        async let wikiLoad = insights.wikiStatus()

        do {
            devices = try await api.list()
            errorMessage = nil
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        do {
            catalogue = try await catalogueLoad
        } catch {
            // The skill catalogue only labels the per-device chips; losing it
            // must not sink the list, but it is why they go blank.
            catalogue = []
            JcLog.dropped(JcLog.more, "devices skill catalogue", error)
        }
        health = await healthLoad
        wiki = await wikiLoad
        isLoading = false
        hasLoaded = true
    }

    // MARK: Mutations

    /// Log the device out — it will need to re-authenticate.
    func logout(_ device: Device) async {
        await mutate { try await self.api.logout(device.id) }
    }

    /// Revoke the device — removed and logged out.
    func revoke(_ device: Device) async {
        await mutate { try await self.api.revoke(device.id) }
    }

    /// Start a pairing window; returns the raw reply (code + expiry).
    func startPair(ttl: Int = 600, label: String? = nil) async -> JSONObject? {
        do {
            return try await api.startPair(ttl: ttl, label: label)
        } catch {
            toast = apiErrorMessage(error)
            return nil
        }
    }

    private func mutate(_ op: () async throws -> Void) async {
        do {
            try await op()
            await refresh()
        } catch {
            toast = "Failed: \(apiErrorMessage(error))"
        }
    }
}

import Combine
import SwiftUI

/// How a linked wearable is doing, in one line.
struct LinkedWearableStatus: Equatable {
    var text: String
    var connected: Bool
}

/// A wearable that can sit inside another — the dashcam inside the car. Linked, its card moves
/// from the Wearables list onto the host's page, its controls join the host's, and the host's
/// CarPlay screen lists it.
@MainActor
protocol LinkableWearable: AnyObject {
    /// The key links are stored under (`"dashcam"`).
    var kind: String { get }
    var title: String { get }
    var symbol: String { get }
    var linkStatus: LinkedWearableStatus { get }
    /// What it adds to its host's Controls.
    var controls: [WearableControl] { get }
    /// Fires when the status or the controls change.
    var changes: AnyPublisher<Void, Never> { get }
    /// Its own Devices card: on the host's page while linked, on the Wearables list while not.
    func card(namespace: Namespace.ID) -> AnyView
    /// Where its CarPlay row opens; nil = nowhere (not set up yet, or no screen of its own).
    var carPlayScreen: CarPlayScreen? { get }
}

/// A wearable others can be linked to — the car.
@MainActor
protocol WearableHost: AnyObject {
    var hostKind: String { get }
    var hostName: String { get }
    func accepts(_ kind: String) -> Bool
    /// The host's own controls, ahead of its children's.
    var ownControls: [WearableControl] { get }
}

/// Which wearable is linked to which, and everything that follows from it. Links are kept on the
/// phone as `[child kind: host kind]`; an empty host is an explicit unlink, so a default link
/// (`defaults`) holds only until the user changes it.
@MainActor
final class WearableLinks: ObservableObject {
    static let shared = WearableLinks()
    static let storeKey = "wearableLinks"
    /// The dashcam and the car lights ride in the car.
    static let defaults: [String: String] = ["dashcam": "car", "lights": "car"]

    /// Bumped on any change a host's page shows: a link, a child's status or controls.
    @Published private(set) var revision = 0

    private let storage: UserDefaults
    private var stored: [String: String]
    private var linkables: [String: any LinkableWearable] = [:]
    private var order: [String] = []
    private var hosts: [String: any WearableHost] = [:]
    private var feeds: [String: AnyCancellable] = [:]

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        stored = storage.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    func register(_ linkable: any LinkableWearable) {
        if linkables[linkable.kind] == nil { order.append(linkable.kind) }
        linkables[linkable.kind] = linkable
        // `objectWillChange`-style feeds fire before the change and very often (the dashcam's
        // transfer progress twice a second): read the child after it lands, and only count a
        // change in what a host shows.
        feeds[linkable.kind] = linkable.changes
            .receive(on: RunLoop.main)
            .map { [weak linkable] in linkable.map(Self.fingerprint) ?? "" }
            .removeDuplicates()
            .sink { [weak self] _ in self?.revision += 1 }
        revision += 1
    }

    func register(host: any WearableHost) {
        hosts[host.hostKind] = host
        revision += 1
    }

    /// The host a kind is linked to, if any.
    func host(of kind: String) -> String? {
        guard let host = stored[kind] ?? Self.defaults[kind], !host.isEmpty else { return nil }
        return host
    }

    func children(of host: String) -> [any LinkableWearable] {
        registered.filter { self.host(of: $0.kind) == host }
    }

    /// What could be linked to `host` that isn't already.
    func candidates(for host: String) -> [any LinkableWearable] {
        guard let accepting = hosts[host] else { return [] }
        return registered.filter { accepting.accepts($0.kind) && self.host(of: $0.kind) != host }
    }

    /// Linkables with no host to show them — their cards stay on the Wearables list. A child
    /// whose host isn't here (not registered) counts as unlinked, so it never disappears.
    var topLevel: [any LinkableWearable] {
        registered.filter { child in host(of: child.kind).map { hosts[$0] == nil } ?? true }
    }

    func link(_ kind: String, to host: String) throws {
        guard let accepting = hosts[host], accepting.accepts(kind) else {
            throw DeviceError.badArgument("\(host) can't take \(kind)")
        }
        save(kind, host)
    }

    func unlink(_ kind: String) { save(kind, "") }

    /// The host's own controls, then each child's; an id is used once.
    func controls(for host: String) -> [WearableControl] {
        var seen = Set<String>()
        let all = (hosts[host]?.ownControls ?? []) + children(of: host).flatMap(\.controls)
        return all.filter { $0.isWellFormed && seen.insert($0.id).inserted }
    }

    func perform(_ id: String, value: WearableControlValue, on host: String) async throws {
        guard let control = controls(for: host).first(where: { $0.id == id }) else {
            throw DeviceError.badArgument("no control '\(id)'")
        }
        guard control.enabled else { throw DeviceError.badArgument("\(control.title) is unavailable right now") }
        try await control.perform(value)
        revision += 1
    }

    /// What a host's page and skills show of a child.
    static func fingerprint(_ child: any LinkableWearable) -> String {
        let controls = child.controls.map { "\($0.id)|\($0.kindName)|\($0.title)|\($0.valueText ?? "")|\($0.enabled)" }
        return ([child.title, child.linkStatus.text, String(child.linkStatus.connected)] + controls).joined(separator: "\u{1F}")
    }

    private var registered: [any LinkableWearable] { order.compactMap { linkables[$0] } }

    private func save(_ kind: String, _ host: String) {
        stored[kind] = host
        storage.set(stored, forKey: Self.storeKey)
        revision += 1
    }
}

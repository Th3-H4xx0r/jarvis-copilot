import Combine
import SwiftUI

/// The dashcam as something linked to the car: the car's page shows its own card, CarPlay's car
/// tab lists it, and its status reads the same as the card's. Its `dashcam_*` skills stay with
/// `DashcamDevice`.
@MainActor
final class DashcamLinkable: LinkableWearable {
    static let shared = DashcamLinkable()

    var sync: DashcamSync = .shared
    var wifi: DashcamWiFi = .shared

    var kind: String { DashcamDevice.identityKey }
    var title: String { DashcamSetupStore.load()?.displayName ?? "Dashcam" }
    var symbol: String { "video" }
    var controls: [WearableControl] { [] }

    var linkStatus: LinkedWearableStatus {
        Self.status(setUp: DashcamSetupStore.load() != nil, onCamera: wifi.onCamera,
                    phase: sync.phase.label, pendingUploads: sync.pendingUploads)
    }

    static func status(setUp: Bool, onCamera: Bool, phase: String, pendingUploads: Int) -> LinkedWearableStatus {
        guard setUp else { return LinkedWearableStatus(text: "Not set up", connected: false) }
        var text = onCamera ? phase : "Away"
        if pendingUploads > 0 { text += " · \(pendingUploads) to upload" }
        return LinkedWearableStatus(text: text, connected: onCamera)
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge(sync.objectWillChange.map { _ in () }, wifi.objectWillChange.map { _ in () })
            .eraseToAnyPublisher()
    }

    func card(namespace: Namespace.ID) -> AnyView { AnyView(DashcamEntryCard(namespace: namespace)) }

    /// The dashcam screens need a camera to show.
    var carPlayScreen: CarPlayScreen? { DashcamSetupStore.load() == nil ? nil : .dashcam }
}

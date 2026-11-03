import Combine
import SwiftUI
@testable import JarvisCopilot

/// A linkable wearable the tests control.
@MainActor
final class FakeLinkable: LinkableWearable {
    let kind: String
    var title: String
    var symbol = "circle"
    var linkStatus = LinkedWearableStatus(text: "Fine", connected: true)
    var controls: [WearableControl] = []
    let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    var carPlayScreen: CarPlayScreen?

    init(kind: String, title: String? = nil) {
        self.kind = kind
        self.title = title ?? kind.capitalized
    }

    func card(namespace: Namespace.ID) -> AnyView { AnyView(Text(title)) }
}

@MainActor
final class FakeHost: WearableHost {
    let hostKind: String
    var hostName: String { hostKind.capitalized }
    var acceptedKinds: Set<String>
    var ownControls: [WearableControl] = []

    init(kind: String = "car", accepts: Set<String>) {
        hostKind = kind
        acceptedKinds = accepts
    }

    func accepts(_ kind: String) -> Bool { acceptedKinds.contains(kind) }
}

/// A control that records what it was asked to do.
@MainActor
final class ControlRecorder {
    var received: [WearableControlValue] = []

    func control(_ id: String, _ kind: WearableControl.Kind, enabled: Bool = true) -> WearableControl {
        WearableControl(id: id, title: Self.title(id), symbol: "power", kind: kind, enabled: enabled) { [weak self] value in
            self?.received.append(value)
        }
    }

    /// The readable name a real control shows ("lights.power" → "Lights", as the car lights
    /// name theirs), never the raw id the renders used to show ("Lights.Power").
    static func title(_ id: String) -> String {
        let name = id.split(separator: ".").last.map(String.init) ?? id
        switch name {
        case "power": return "Lights"
        case "color": return "Colour"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// A fresh, empty defaults domain per test.
func isolatedDefaults(_ function: String = #function) -> UserDefaults {
    let name = "car-tests.\(function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

import AVFAudio
import Combine
import Foundation
import UIKit

/// Whether the phone is with the car: Jarvis is up on CarPlay, the audio is going to the car,
/// or the phone is on the dashcam's Wi‑Fi. Any one is enough.
@MainActor
final class CarPresence: ObservableObject {
    static let shared = CarPresence()
    private static let lastSeenKey = "jc.car.lastSeen"

    @Published private(set) var inCar = false
    /// When the phone was last with the car (stamped on the way in and on the way out).
    @Published private(set) var lastSeen: Date?

    private var carPlay = false
    private var carAudio = false
    private var onDashcam = false
    private var started = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        lastSeen = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date
    }

    static func isInCar(carPlay: Bool, carAudio: Bool, onDashcam: Bool) -> Bool {
        carPlay || carAudio || onDashcam
    }

    /// Follow the audio route and the dashcam's Wi‑Fi. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.readRoute() }
            .store(in: &cancellables)
        // A route change missed while suspended (CarPlay unplugged) would leave "In the car" on.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.readRoute() }
            .store(in: &cancellables)
        // Killed mid-drive, the last stamp would be the drive's start: stamp on the way out too.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.stampIfInCar() }
            .store(in: &cancellables)
        DashcamWiFi.shared.$onCamera
            .removeDuplicates()
            .sink { [weak self] on in
                self?.onDashcam = on
                self?.update()
            }
            .store(in: &cancellables)
        readRoute()
    }

    /// From the CarPlay scene: Jarvis's car screen connected or went away.
    func setCarPlay(_ on: Bool) {
        carPlay = on
        update()
    }

    private func readRoute() {
        carAudio = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        update()
    }

    private func stampIfInCar() {
        guard inCar else { return }
        lastSeen = Date()
        UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey)
    }

    private func update() {
        let now = Self.isInCar(carPlay: carPlay, carAudio: carAudio, onDashcam: onDashcam)
        if now || inCar {
            lastSeen = Date()
            UserDefaults.standard.set(lastSeen, forKey: Self.lastSeenKey)
        }
        if now != inCar { inCar = now }
    }
}

import CoreMotion
import SwiftUI

/// The Holo Drop popup's state, shared by the app and the share extension.
@MainActor
final class HoloOrbitModel: ObservableObject {
    enum Phase: Equatable { case loading, choosing, aiming(HoloDevice), sending(HoloDevice), done(HoloSendResult) }

    @Published var phase: Phase = .loading
    @Published var devices: [HoloDevice] = []
    @Published var heading: Double?
    @Published var override: HoloAction?          // this drop only; nil = the device's default
    @Published var screen: HoloScreen?
    @Published var aim = HoloPosition.center
    @Published var tilt = CGSize.zero             // tilt-to-aim offset, fractions of the screen
    @Published var errorText: String?
    let item: HoloItem
    let client: HoloDropClient
    var onFinish: () -> Void = {}
    private let motion = CMMotionManager()

    init(item: HoloItem, client: HoloDropClient) {
        self.item = item
        self.client = client
    }

    func load() async {
        do {
            devices = try await client.devices().filter { $0.accepts(item) }
            phase = .choosing
        } catch {
            errorText = error.localizedDescription
            phase = .done(.failed(error.localizedDescription))
        }
        startHeading()
    }

    func action(for device: HoloDevice) -> HoloAction { override ?? device.defaultAction }

    func pick(_ device: HoloDevice) {
        if device.aim {
            phase = .aiming(device)
            aim = .center
            startTilt()
            Task { screen = try? await client.screen(of: device) }
        } else {
            Task { await send(to: device, position: nil) }
        }
    }

    func send(to device: HoloDevice, position: HoloPosition?) async {
        stopTilt()
        phase = .sending(device)
        do {
            let reply = try await client.send(item, to: device, action: action(for: device), position: position?.clamped())
            let state = (reply["drop"] as? [String: Any])?["state"] as? String ?? ""
            switch state {
            case "landed": phase = .done(.landed("Landed on \(device.name)"))
            case "held": phase = .done(.sent("Held for \(device.name) — it gets it when it's back"))
            default: phase = .done(.sent("Sent to \(device.name)"))
            }
        } catch {
            phase = .done(.failed(error.localizedDescription))
        }
    }

    // MARK: sensors (heading for real bearings; attitude for tilt-to-aim)

    private func startHeading() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / 15
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let deg = m.heading >= 0 ? m.heading : nil
            if let deg, abs(HoloOrbitLayout.angleDelta(deg, self.heading ?? -999)) > 2 { self.heading = deg }
            if case .aiming = self.phase {
                self.tilt = CGSize(width: max(-0.4, min(0.4, m.attitude.roll * 0.6)),
                                   height: max(-0.4, min(0.4, m.attitude.pitch * 0.6)))
            }
        }
    }

    private func startTilt() { tilt = .zero }
    private func stopTilt() { tilt = .zero }

    func stopSensors() { motion.stopDeviceMotionUpdates() }
}

/// The Orbit: the item in the middle, your devices around it at their real bearings when
/// known. Fling the item toward one, or tap one. Black & white, per the approved mockup.
struct HoloOrbitView: View {
    @ObservedObject var model: HoloOrbitModel
    @State private var drag = CGSize.zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .loading:
                ProgressView().tint(.white)
            case .choosing:
                orbit
            case .aiming(let device):
                HoloScreenMapView(model: model, device: device)
            case .sending(let device):
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Sending to \(device.name)…").foregroundStyle(.white.opacity(0.7)).font(.system(size: 14))
                }
            case .done(let result):
                HoloResultView(result: result)
            }
        }
        .task { await model.load() }
        .onDisappear { model.stopSensors() }
    }

    private var orbit: some View {
        GeometryReader { geo in
            let positions = HoloOrbitLayout.positions(devices: model.devices, heading: model.heading, size: geo.size)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.48)
            ZStack {
                Text("HOLO DROP").font(.system(size: 13, weight: .medium)).tracking(1)
                    .foregroundStyle(.white.opacity(0.5)).position(x: geo.size.width / 2, y: 40)
                ForEach(model.devices) { d in
                    if let p = positions[d.id] {
                        HoloBubble(device: d, hot: hotDevice(positions: positions, center: center) == d.id)
                            .position(p)
                            .onTapGesture { model.pick(d) }
                            .animation(.spring(duration: 0.35), value: p)
                    }
                }
                HoloItemCard(item: model.item)
                    .offset(drag)
                    .position(center)
                    .gesture(DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { g in
                            let v = CGVector(dx: g.predictedEndTranslation.width - g.translation.width,
                                             dy: g.predictedEndTranslation.height - g.translation.height)
                            let vel = CGVector(dx: v.dx * 4, dy: v.dy * 4)
                            if let id = HoloOrbitLayout.target(forVelocity: vel, from: center, positions: positions),
                               let d = model.devices.first(where: { $0.id == id }) {
                                withAnimation(.easeIn(duration: 0.2)) { drag = CGSize(width: v.dx * 3, height: v.dy * 3) }
                                model.pick(d)
                            } else {
                                withAnimation(.spring) { drag = .zero }
                            }
                        })
                Text(model.devices.isEmpty ? "No devices to drop onto right now" : "Fling toward a device · or tap one")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .position(x: geo.size.width / 2, y: geo.size.height - 92)
                HoloActionChips(model: model, device: model.devices.first)
                    .position(x: geo.size.width / 2, y: geo.size.height - 48)
            }
        }
    }

    /// The bubble the item is being dragged toward.
    private func hotDevice(positions: [String: CGPoint], center: CGPoint) -> String? {
        guard abs(drag.width) + abs(drag.height) > 30 else { return nil }
        return HoloOrbitLayout.target(forVelocity: CGVector(dx: drag.width * 20, dy: drag.height * 20),
                                      from: center, positions: positions)
    }
}

struct HoloBubble: View {
    let device: HoloDevice
    var hot = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: device.symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().stroke(hot ? Color.white : Color.white.opacity(0.22), lineWidth: hot ? 1.5 : 1))
                .shadow(color: hot ? .white.opacity(0.35) : .clear, radius: 12)
                .opacity(device.online ? 1 : 0.55)
            Text(device.name).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                .frame(maxWidth: 76)
        }
        .accessibilityLabel("Drop on \(device.name)")
    }
}

struct HoloItemCard: View {
    let item: HoloItem

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: item.symbol).font(.system(size: 28)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(Color.white.opacity(0.06))
            Text(item.caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).padding(8)
        }
        .frame(width: 124)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// Save / Open / Copy / Save + Open / Save + Copy — this drop only; the device default is
/// selected until you pick another.
struct HoloActionChips: View {
    @ObservedObject var model: HoloOrbitModel
    let device: HoloDevice?

    var body: some View {
        let current = model.override ?? device?.defaultAction ?? .open
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HoloAction.allCases) { a in
                    Text(a.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(a == current ? Color.black : .white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(a == current ? Color.white : Color.white.opacity(0.08)))
                        .onTapGesture { model.override = a }
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

struct HoloResultView: View {
    let result: HoloSendResult

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white)
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var icon: String {
        switch result {
        case .landed: return "checkmark.circle"
        case .sent: return "paperplane"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var text: String {
        switch result {
        case .landed(let t), .sent(let t), .failed(let t): return t
        }
    }
}

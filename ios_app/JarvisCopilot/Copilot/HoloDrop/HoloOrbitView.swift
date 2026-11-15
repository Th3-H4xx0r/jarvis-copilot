import CoreMotion
import SwiftUI
import ImageIO
import UIKit

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
    /// The drop's story is told (landed / failed / held, or the landing wait ran out): a popup may close.
    @Published var settled = false
    /// What's being dropped (the app's popup can switch it from its tray).
    @Published var item: HoloItem
    /// A physical throw picked this device: the card flies to its bubble, then it's sent.
    @Published var flung: String?
    /// The Orbit's size, from the view: a throw resolves against the bubbles' real positions.
    var layoutSize: CGSize = .zero
    private var fling = HoloFlingDetector(armedAt: ProcessInfo.processInfo.systemUptime)
    /// Sent right after `item` to the same device (a screenshot's best-guess link).
    @Published var extra: HoloItem?
    let client: HoloDropClient
    var onFinish: () -> Void = {}
    private let motion = CMMotionManager()

    init(item: HoloItem, client: HoloDropClient) {
        self.item = item
        self.client = client
    }

    func load() async {
        do {
            serverDevices = try await client.devices().filter { $0.accepts(item) }
            devices = serverDevices
            phase = .choosing
            fling = HoloFlingDetector(armedAt: ProcessInfo.processInfo.systemUptime)
        } catch {
            errorText = error.localizedDescription
            phase = .done(.failed(error.localizedDescription))
            settled = true
        }
        startHeading()
    }

    func action(for device: HoloDevice) -> HoloAction { override ?? device.defaultAction }

    /// The app's live sensing (the share extension has none): readings + the nearest device.
    func applyLive(_ live: [String: HoloLiveReading], nearest: String?) {
        devices = serverDevices.map { $0.applying(live[$0.id], nearest: $0.id == nearest) }
    }
    private var serverDevices: [HoloDevice] = []

    func pick(_ device: HoloDevice) {
        if case .text(let t) = item, t.isEmpty {
            errorText = "Pick something from the top first"
            return
        }
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
            if let extra, device.accepts(extra) {
                _ = try? await client.send(extra, to: device, action: action(for: device), position: position?.clamped())
            }
            let drop = reply["drop"] as? [String: Any] ?? [:]
            phase = .done(Self.result(drop, device: device))
            if case .done(.sent) = phase, drop["state"] as? String != "held", let id = drop["id"] as? String {
                await waitForLanding(id, device: device)
            }
        } catch {
            phase = .done(.failed(error.localizedDescription))
        }
        settled = true
    }

    /// What the popup says for a drop record: landed (with what happened), held, failed, sent.
    static func result(_ drop: [String: Any], device: HoloDevice) -> HoloSendResult {
        switch drop["state"] as? String ?? "" {
        case "landed":
            let outcome = drop["outcome"] as? String ?? ""
            let words = HoloOutcomeWords.text(outcome)
            return .landed(words.isEmpty ? "Landed on \(device.name)" : "Landed on \(device.name) · \(words)")
        case "held": return .sent("Sent — waiting for \(device.name)")
        case "failed": return .failed("\(device.name) couldn't take it\((drop["error"] as? String).map { ": \($0)" } ?? "")")
        default: return .sent("Sent to \(device.name)")
        }
    }

    /// The app hears every landing over the bridge; it shows a banner for those no popup showed.
    static var showedLanding: (String) -> Void = { _ in }

    /// A few seconds for the landing; after that the sender hears by notification.
    private func waitForLanding(_ id: String, device: HoloDevice) async {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(700))
            guard let d = try? await client.drop(id) else { continue }
            let state = d["state"] as? String
            if state == "landed" || state == "failed" {
                phase = .done(Self.result(d, device: device))
                Self.showedLanding(id)
                return
            }
        }
    }

    // MARK: sensors (heading for real bearings; attitude for tilt-to-aim)

    private func startHeading() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / 60           // fast enough to see a throw
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let deg = m.heading >= 0 ? m.heading : nil
            if let deg, abs(HoloOrbitLayout.angleDelta(deg, self.heading ?? -999)) > 2 { self.heading = deg }
            if self.phase == .choosing, self.flung == nil {
                let a = m.userAcceleration
                if let flick = self.fling.add(HoloMotionSample(t: m.timestamp, a: SIMD3(a.x, a.y, a.z))) {
                    self.thrown(flick)
                }
            }
            if case .aiming = self.phase {
                // Relative to how he held the phone when aiming began (not the absolute angle).
                if self.tiltRef == nil { self.tiltRef = (m.attitude.roll, m.attitude.pitch) }
                let ref = self.tiltRef ?? (0, 0)
                self.tilt = HoloTilt.offset(roll: m.attitude.roll, pitch: m.attitude.pitch, refRoll: ref.0, refPitch: ref.1)
            }
        }
    }

    /// A physical throw: send to the device it points at (or the bubble on that side).
    private func thrown(_ flick: HoloFlick) {
        let size = layoutSize == .zero ? CGSize(width: 390, height: 760) : layoutSize
        let positions = HoloOrbitLayout.positions(devices: devices, heading: heading, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
        guard let id = HoloFling.target(flick, heading: heading, devices: devices, positions: positions, center: center),
              let device = devices.first(where: { $0.id == id }) else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            errorText = "Point the phone at a device and throw — or flick toward its bubble"
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: min(1, flick.strength / 3))
        flung = id
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            pick(device)
            flung = nil
        }
    }

    private var tiltRef: (Double, Double)?
    private func startTilt() { tilt = .zero; tiltRef = nil }
    private func stopTilt() { tilt = .zero; tiltRef = nil }

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
        .background(GeometryReader { g in Color.clear.onAppear { model.layoutSize = g.size }
            .onChange(of: g.size) { _, size in model.layoutSize = size } })
        .task { await model.load() }
        .onDisappear { model.stopSensors() }
    }

    private var orbit: some View {
        GeometryReader { geo in
            let positions = HoloOrbitLayout.positions(devices: model.devices, heading: model.heading, size: geo.size)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.48)
            let flyTo = model.flung.flatMap { positions[$0] }
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
                    .scaleEffect(flyTo == nil ? 1 : 0.35)
                    .opacity(flyTo == nil ? 1 : 0.2)
                    .offset(flyTo.map { CGSize(width: $0.x - center.x, height: $0.y - center.y) } ?? drag)
                    .animation(.easeIn(duration: 0.25), value: model.flung)
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
                Text(model.devices.isEmpty ? "No devices to drop onto right now"
                     : (model.errorText ?? "Throw the phone toward a device · or flick / tap one"))
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
                .overlay(Circle().stroke(hot ? Color.white : Color.white.opacity(device.nearest ? 0.6 : 0.22),
                                         lineWidth: hot ? 1.5 : 1))
                .shadow(color: hot ? .white.opacity(0.35) : .clear, radius: 12)
                .opacity(device.online ? 1 : 0.55)
            Text(device.name).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                .frame(maxWidth: 76)
            if device.nearest || device.distance != nil {
                Text(device.distance.map { $0 < 1 ? "here" : String(format: "%.0f m", $0) } ?? "nearest")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .accessibilityLabel("Drop on \(device.name)")
    }
}

struct HoloItemCard: View {
    let item: HoloItem

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if case .file(let url, _, _, "image") = item, let image = HoloThumb.image(url) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.symbol).font(.system(size: 28)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 124, height: 96).clipped()
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
        // Nothing is lit until he picks one: each device then does its own default.
        let current = model.override
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HoloAction.allCases) { a in
                    Text(a.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(a == current ? Color.black : .white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(a == current ? Color.white : Color.white.opacity(0.08)))
                        .onTapGesture { model.override = model.override == a ? nil : a }
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

/// Tilt-to-aim: how far he's tipped the phone since aiming began, as a fraction of the screen.
enum HoloTilt {
    static func offset(roll: Double, pitch: Double, refRoll: Double, refPitch: Double) -> CGSize {
        CGSize(width: max(-0.4, min(0.4, (roll - refRoll) * 0.6)),
               height: max(-0.4, min(0.4, (pitch - refPitch) * 0.6)))
    }
}

/// Small thumbnails for the item card, decoded once (a full photo per redraw would stutter).
enum HoloThumb {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(_ url: URL, max: CGFloat = 320) -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

import SwiftUI

/// Aiming on a Mac: a small map of its screen (window outlines); drag the item to where it
/// should land, or tilt the phone to nudge it. Drop → the card lands there on the Mac.
struct HoloScreenMapView: View {
    @ObservedObject var model: HoloOrbitModel
    let device: HoloDevice
    @State private var dragStart: HoloPosition?

    var body: some View {
        VStack(spacing: 16) {
            Text("DROP ON \(device.name.uppercased())").font(.system(size: 13, weight: .medium)).tracking(1)
                .foregroundStyle(.white.opacity(0.5)).padding(.top, 28)
            GeometryReader { geo in
                let size = mapSize(in: geo.size)
                let spot = HoloScreenMapView.combined(model.aim, tilt: model.tilt)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2)))
                    if let screen = model.screen {
                        ForEach(Array(screen.windows.enumerated()), id: \.offset) { _, w in
                            RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.18))
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
                                .frame(width: w.rect.width / screen.size.width * size.width,
                                       height: w.rect.height / screen.size.height * size.height)
                                .offset(x: w.rect.minX / screen.size.width * size.width,
                                        y: w.rect.minY / screen.size.height * size.height)
                        }
                    }
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                        .frame(width: 46, height: 34)
                        .offset(x: spot.x * size.width - 23, y: spot.y * size.height - 17)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        model.aim = HoloPosition(x: g.location.x / size.width, y: g.location.y / size.height).clamped()
                    })
                .frame(maxWidth: .infinity)
            }
            .frame(height: 220)
            .padding(.horizontal, 18)
            Text(model.screen == nil ? "Drag to where it should land" : "Drag (or tilt) to where it should land")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            HoloActionChips(model: model, device: device)
            Button {
                Task { await model.send(to: device, position: HoloScreenMapView.combined(model.aim, tilt: model.tilt)) }
            } label: {
                Text("Drop here").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(Color.white))
            }
            .padding(.horizontal, 24)
            Button("Back") { model.phase = .choosing }.foregroundStyle(.white.opacity(0.6)).font(.system(size: 13))
            Spacer(minLength: 0)
        }
    }

    private func mapSize(in available: CGSize) -> CGSize {
        let aspect = model.screen.map { $0.size.height / $0.size.width } ?? 0.625
        let w = min(available.width, available.height / aspect)
        return CGSize(width: w, height: w * aspect)
    }

    /// The landing spot: where he dragged, nudged by tilt.
    static func combined(_ aim: HoloPosition, tilt: CGSize) -> HoloPosition {
        HoloPosition(x: aim.x + tilt.width, y: aim.y + tilt.height).clamped()
    }
}

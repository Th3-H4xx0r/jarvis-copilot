import MapKit
import SwiftUI

/// Location: where the car was last parked, with directions in Apple Maps.
struct CarLocationScreen: View {
    let car: ToyotaCar?

    var body: some View {
        Group {
            if let location = car?.location {
                Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                                                                latitudinalMeters: 700, longitudinalMeters: 700))) {
                    Marker(CarDevice.shared.name, systemImage: "car.fill", coordinate: location.coordinate)
                        .tint(JcTheme.accent)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        if let at = location.at {
                            Text("Parked \(at, format: .relative(presentation: .named))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            directions(to: location)
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.jcGlass(full: true))
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                }
            } else {
                ContentUnavailableView("No location yet", systemImage: "mappin.slash",
                                       description: Text("Toyota hasn't reported where the car is parked."))
            }
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func directions(to location: ToyotaCar.Location) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        item.name = CarDevice.shared.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

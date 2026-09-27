import SwiftUI
import MapKit
import CoreLocation

/// The places the GO3's Navigation app lists (Home, Work, others), plus what the
/// navigator is doing. Open Navigation on the glasses to pick one.
struct GlassesPlacesView: View {
    @ObservedObject private var places = GlassesPlaces.shared
    @ObservedObject private var navigator = GlassesNavigator.shared
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var picked: MKMapItem?
    @State private var starting: UUID?
    @State private var startError: String?
    @State private var locationStatus = CLLocationManager().authorizationStatus
    private let locationAsker = CLLocationManager()

    var body: some View {
        List {
            statusSection
            if locationStatus != .authorizedAlways {
                Section {
                    Button("Allow location “Always”") { locationAsker.requestAlwaysAuthorization() }
                } footer: {
                    Text("Lets turn-by-turn keep going with the phone locked in your pocket.")
                }
            }
            Section {
                HStack {
                    TextField("Search a place", text: $query)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if searching { ProgressView() }
                }
                ForEach(results, id: \.self) { item in
                    Button { picked = item } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Place").foregroundStyle(JcTheme.text)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(JcTheme.muted).lineLimit(1)
                        }
                    }
                }
            } header: { Text("Add a place") }
            Section {
                if places.places.isEmpty {
                    Text("No places yet. Add Home and Work so they show up in Navigation on the glasses.")
                        .font(.subheadline).foregroundStyle(JcTheme.muted)
                }
                ForEach(places.places.sorted { $0.lensType < $1.lensType }) { place in
                    HStack(spacing: 12) {
                        JcIcon(place.kind == .home ? "house.fill" : place.kind == .work ? "briefcase.fill" : "mappin")
                            .foregroundStyle(JcTheme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).foregroundStyle(JcTheme.text)
                            Text(place.kind == .other ? place.detail : "\(place.kind.rawValue.capitalized) · \(place.detail)")
                                .font(.caption).foregroundStyle(JcTheme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if starting == place.id {
                            ProgressView()
                        } else {
                            startButton(place, walking: true)
                            startButton(place, walking: false)
                        }
                    }
                    .contextMenu {
                        Button("Set as Home") { places.setKind(.home, for: place) }
                        Button("Set as Work") { places.setKind(.work, for: place) }
                        Button("Make it Other") { places.setKind(.other, for: place) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { places.remove(place) } }
                }
            } header: { Text("On the glasses") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let startError { Text(startError).foregroundStyle(.red) }
                    Text("Tap the walk or bike button to start directions on the glasses now. Or open Navigation on the glasses and pick a place, or ask Jarvis: “take me to …”.")
                }
            }
        }
        .navigationTitle("Navigation")
        .confirmationDialog(picked?.name ?? "Save place", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
            ForEach(GlassesPlace.Kind.allCases, id: \.self) { kind in
                Button("Save as \(kind == .other ? "a place" : kind.rawValue.capitalized)") { save(kind) }
            }
        }
        .onAppear { locationStatus = locationAsker.authorizationStatus }
    }

    @ViewBuilder private var statusSection: some View {
        if navigator.state != .idle || navigator.lastError != nil {
            Section {
                if let name = navigator.destinationName, navigator.state != .idle {
                    LabeledContent("To", value: name)
                    LabeledContent("Status", value: navigator.state.rawValue.capitalized)
                    if let u = navigator.last, navigator.state == .guiding {
                        LabeledContent("Next", value: "\(u.roadName) in \(u.toManeuver) m")
                        LabeledContent("Left", value: "\(u.remaining) m · \(u.remainingSeconds / 60) min · \(u.reachTime)")
                    }
                    Button("Stop navigation", role: .destructive) { navigator.stop(fromLens: false) }
                }
                if let error = navigator.lastError { Text(error).font(.caption).foregroundStyle(JcTheme.muted) }
            } header: { Text("Now") }
        }
    }

    private func startButton(_ place: GlassesPlace, walking: Bool) -> some View {
        Button {
            starting = place.id; startError = nil
            Task {
                do { try await navigator.start(to: place, walking: walking) }
                catch { startError = error.localizedDescription }
                starting = nil
            }
        } label: {
            JcIcon(walking ? "figure.walk" : "bicycle")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(JcTheme.accent)
        .accessibilityLabel(walking ? "Walk to \(place.name)" : "Bike to \(place.name)")
        .disabled(starting != nil)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let here = locationAsker.location { request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000) }
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }

    private func save(_ kind: GlassesPlace.Kind) {
        guard let item = picked else { return }
        places.add(kind: kind, name: kind == .other ? (item.name ?? "Place") : (item.name ?? kind.rawValue.capitalized),
                   detail: item.placemark.title ?? "", coordinate: item.placemark.coordinate)
        picked = nil; results = []; query = ""
    }
}

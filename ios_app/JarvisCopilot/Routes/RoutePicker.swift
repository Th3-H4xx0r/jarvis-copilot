import SwiftUI

/// Choose a past route to follow: those on this phone, and those Jarvis
/// Health has from before (a reinstall, another phone).
struct RoutePicker: View {
    @Binding var guide: RouteGuide?
    @ObservedObject private var store = RouteStore.shared
    @State private var remote: [RingWorkout] = []
    @State private var loading: String?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jc.distance.unit") private var unitRaw = DistanceUnit.current.rawValue

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .regional }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    CardGroup(footer: "The route is drawn on the map as you go, with the distance left, and you're told when you stray from it.") {
                        Button {
                            guide = nil
                            dismiss()
                        } label: {
                            Row(minHeight: 56) {
                                HStack(spacing: 12) {
                                    Image(systemName: "record.circle").foregroundStyle(.secondary).frame(width: 40)
                                    Text("Just record").foregroundStyle(.primary)
                                    Spacer()
                                    if guide == nil { Image(systemName: "checkmark").foregroundStyle(JcTheme.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if !store.index.isEmpty {
                        CardGroup("On this iPhone") {
                            ForEach(Array(store.index.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { RowDivider() }
                                row(id: entry.id, name: entry.sportName, date: entry.start, meters: entry.distance,
                                    preview: entry.preview) {
                                    guard let route = store.route(start: entry.start) else { return failed = true }
                                    pick(route, name: entry.sportName, sport: entry.sport, start: entry.start)
                                }
                            }
                        }
                    }
                    if !remote.isEmpty {
                        CardGroup("From Jarvis Health") {
                            ForEach(Array(remote.enumerated()), id: \.element.id) { index, workout in
                                if index > 0 { RowDivider() }
                                row(id: RouteStore.key(workout.start), name: workout.sportName, date: workout.start,
                                    meters: workout.route?.distanceMeters ?? workout.distanceMeters,
                                    preview: workout.route?.preview ?? "") {
                                    loading = RouteStore.key(workout.start)
                                    Task {
                                        let route = await store.load(workout)
                                        loading = nil
                                        guard let route else { return failed = true }
                                        pick(route, name: workout.sportName, sport: workout.sport, start: workout.start)
                                    }
                                }
                            }
                        }
                    }
                    if store.index.isEmpty && remote.isEmpty {
                        CardGroup {
                            CardEmptyBlock(symbol: "map", text: "No routes yet — finish an outdoor workout and it's here to follow.")
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .jcScreen("Follow a route")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("That route couldn't be loaded", isPresented: $failed) { Button("OK", role: .cancel) {} }
            .task { await fetchRemote() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(id: String, name: String, date: Date, meters: Double, preview: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Row(minHeight: 60) {
                HStack(spacing: 12) {
                    RouteThumbnail(preview: preview, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(.primary)
                        Text("\(date.formatted(.dateTime.month(.abbreviated).day().year())) · \(unit.distance(meters)) \(unit.symbol)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading == id {
                        ProgressView()
                    } else if guide?.id == id {
                        Image(systemName: "checkmark").foregroundStyle(JcTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(loading != nil)
    }

    private func pick(_ route: WorkoutRoute, name: String, sport: Int, start: Date) {
        let title = "\(name) · \(start.formatted(.dateTime.month(.abbreviated).day()))"
        guide = RouteGuide(route: route, title: title, sport: sport, start: start)
        dismiss()
    }

    private func fetchRemote() async {
        let client = HealthClient(spaceID: HealthSpace.shared)
        let since = HealthClient.instant.string(from: Date().addingTimeInterval(-400 * 86_400))
        guard let object = try? await client.api.get("\(client.base)/workouts", query: ["since": since]).object(),
              let workouts = try? HealthClient.decode([RingWorkout].self, from: object["workouts"] ?? []) else { return }
        remote = workouts.filter { $0.route != nil && !store.hasRoute(start: $0.start) }.sorted { $0.start > $1.start }
    }
}

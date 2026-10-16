import SwiftUI

/// Settings → CarPlay: which app Jarvis's voice directions open in, and where the
/// Talk to Jarvis button lives.
struct CarPlaySettingsScreen: View {
    private let preferences: KeyValueStore = UserDefaults.standard
    @State private var app = CarMapsApp.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 0) {
                    GlassQuietLabel("Directions app")
                    GlassGroup {
                        ForEach(Array(CarMapsApp.allCases.enumerated()), id: \.element) { index, option in
                            LiveRadioRow(title: option.title,
                                         subtitle: option == .waze ? "Starts guidance by itself" : nil,
                                         selected: option == app,
                                         last: index == CarMapsApp.allCases.count - 1,
                                         action: { choose(option) })
                        }
                    }
                    LiveSettingsNote("\"Take me to …\" while driving opens here, on the car's screen, "
                        + "once Jarvis has said where it's going.")
                }
                VStack(alignment: .leading, spacing: 0) {
                    GlassQuietLabel("Talk to Jarvis button")
                    LiveSettingsNote("On the iPhone: Settings → General → CarPlay → your car → Customize, "
                        + "then add \"Talk to Jarvis (car)\" to CarPlay's Widgets page. One tap talks "
                        + "without leaving the screen, a second tap stops.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .jcScreen("CarPlay")
    }

    private func choose(_ option: CarMapsApp) {
        app = option
        preferences.set(option.rawValue, forKey: CarMapsApp.key)
    }
}

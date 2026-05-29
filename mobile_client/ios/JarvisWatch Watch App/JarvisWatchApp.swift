import SwiftUI

@main
struct JarvisWatchApp: App {
    @StateObject private var connector = WatchConnector()

    var body: some Scene {
        WindowGroup {
            ContentView(connector: connector)
        }
    }
}

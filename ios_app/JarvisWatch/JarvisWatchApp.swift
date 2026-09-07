import CoreText
import SwiftUI

@main
struct JarvisWatchApp: App {
    @StateObject private var connector = WatchConnector()

    init() {
        // The watch app uses an auto-generated Info.plist (no UIAppFonts), so
        // register the bundled Inter faces at launch instead. The .ttf files live
        // in Fonts/ and are auto-bundled (synchronized folder). Same family as
        // the mobile app so the two surfaces share one typeface.
        for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(connector: connector)
        }
    }
}

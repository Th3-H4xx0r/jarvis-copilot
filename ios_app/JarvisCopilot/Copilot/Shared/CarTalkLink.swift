import Foundation

/// The CarPlay Talk widget's orb: opens Jarvis on the car's screen already
/// listening, for one answer. iOS won't let a backgrounded app start the mic
/// (`!int`), so the orb doesn't try — Apple's way for a CarPlay app's widget is a
/// link, which brings the app forward on the car. Compiled into the app and the widget.
enum CarTalkLink {
    static let url = URL(string: "jarviscopilot://voice?once=1")!
}

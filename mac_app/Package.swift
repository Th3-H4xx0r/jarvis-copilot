// swift-tools-version: 5.9
import PackageDescription

// The Mac voice UI: the phone's voice flow, built for macOS.
//
// `Sources/JarvisVoiceUI/Voice` and `.../Core` are SYMLINKS into the iOS app —
// the same files the phone builds, not a copy. There is one implementation of
// the turn machine, the endpointer, the audio queue and the orb, and it runs on
// both. Only the shims beside them are Mac-specific.
//
// It builds a DYNAMIC library rather than an app: the tray is a Python process
// that already owns the menubar item and the popover, and loading this dylib
// registers its @objc classes with the Obj-C runtime, so that popover can host a
// real SwiftUI view instead of a web page.
let package = Package(
    name: "JarvisVoiceUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisVoiceUI", type: .dynamic, targets: ["JarvisVoiceUI"]),
    ],
    targets: [
        .target(
            name: "JarvisVoiceUI",
            path: "Sources/JarvisVoiceUI",
            // The iOS page layout — the only file in the shared tree that needs
            // UIKit. The Mac has its own panel (MacVoicePanel.swift); everything
            // underneath it is shared.
            exclude: [
                // The iOS page and its pickers: they are built from the phone's
                // design system and its chat/session layers, none of which the
                // Mac panel uses. The voice loop underneath them is shared.
                "Voice/VoicePage.swift",
                "Voice/Views/VoiceEnginePicker.swift",
                "Voice/Views/VoiceSessionPicker.swift",
                "Voice/Views/VoiceModelPickerSheet.swift",
                "Voice/VoiceModelSelection.swift",
                // On-device routing — a phone feature that drags in the whole
                // local-model stack.
                "Voice/VoiceLocalLane.swift",
            ],
            // What the shared sources test to know they are in THIS build: the
            // phone's voice loop without the phone's chat UI, navigation shell
            // and on-device model. The handful of `#if JC_MAC_VOICE` in the
            // shared tree are all of that shape — a layer this target leaves
            // out — and never a real iOS/macOS difference, which stays
            // `#if os(iOS)`.
            swiftSettings: [.define("JC_MAC_VOICE")]
        ),
    ]
)

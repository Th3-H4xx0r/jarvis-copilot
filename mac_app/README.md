# mac_app — the Mac voice client, in Swift

The phone's voice flow, built for macOS. `Sources/JarvisVoiceUI/Voice` and `.../Core` are
**symlinks** into `ios_app/JarvisCopilot/Copilot/` — the same files the phone builds, not a
copy, so the turn machine, endpointer, audio queue and orb have one implementation.

It builds a **dynamic library**, not an app: the tray is a Python process that already owns the
menubar item and its popover, and loading this dylib registers its `@objc` classes with the
Obj-C runtime, so the popover can host a real SwiftUI view instead of a web page.

Credentials are not its problem. `JarvisAPI` takes them through a protocol, so on macOS it is
pointed at `http://127.0.0.1:<port>` — the loopback proxy the Python client already runs, which
does the TLS pinning and injects the session cookie.

    swift build          # from this directory

## What is excluded, and why

`Package.swift` leaves out the phone's page and its pickers (they are built from the app's
design system and its chat/session layers) and the on-device local lane (which pulls in the
whole local-model stack). The voice loop underneath them is shared.

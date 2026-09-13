# mac_app — the Mac voice client, in Swift

The phone's voice flow, built for macOS. `Sources/JarvisVoiceUI/{Voice,Core}` are **symlinks**
into `ios_app/JarvisCopilot/Copilot/` — the same files the phone builds, not a copy, so the turn
machine, endpointer, audio queue and orb have one implementation. `Chat/` and `Shared/` symlink
the handful of individual files the voice stack needs from the layers around it, by file rather
than by directory, so a new file on the phone does not silently join this build.

It builds a **dynamic library**, not an app: the tray is a Python process that already owns the
menubar item and its popover, and loading this dylib registers its `@objc` classes with the
Obj-C runtime, so the popover can host a real SwiftUI view instead of a web page.

Credentials are not its problem. `JarvisAPI` takes them through a protocol, so on macOS it is
pointed at `http://127.0.0.1:<port>` — the loopback proxy the Python client already runs, which
does the TLS pinning and injects the session cookie.

    ./build.sh          # release dylib + bundle, installed into the client
    swift build         # compile only

**Use `build.sh`, not `swift build`, for anything you intend to run.** SwiftPM copies `.metal`
files into the resource bundle but never runs the Metal compiler on them, so a `swift build`
alone leaves the orb with no shader — and SwiftUI has no error channel for a missing shader
function, so it simply draws nothing. `build.sh` compiles the metallib and installs the dylib
and its bundle together into `desktop_client/jc_client/assets/`, which is where the client loads
them from and where they are committed. **Re-run it after touching anything under `mac_app/` or
the phone's `Voice`/`Core` sources**, or the client keeps running the last build.

## What the Mac has that the phone doesn't

`Mac/` is the only non-shared code:

* `MacVoicePanel.swift` — the panel. The orb, the karaoke reply and the controls are the phone's;
  what differs is the frame, because a 400×560 popover has no navigation bar, tab bar or sheets,
  which is what `VoicePage` is built from.
* `JarvisVoicePanel.swift` — the whole surface the tray can reach:
  `+makeViewControllerWithBaseURL:`, `orbShaderAvailable`, `stopEverything`.
* `MacResources.swift` — finds this library's resource bundle with `dladdr`. Not `Bundle.module`:
  SwiftPM generates that to look beside `Bundle.main` (here the Python tray, which knows nothing
  about us) and otherwise at an absolute `.build/` path from the machine that compiled it — so it
  works on the build machine, `fatalError`s everywhere else, and takes the tray down with it.

## The two kinds of `#if` in the shared tree

* `#if os(iOS)` — a real platform difference. macOS has no `AVAudioSession`, so the arbiter keeps
  its claim bookkeeping and applies nothing; and credentials come from the proxy rather than the
  paired-device bridge.
* `#if JC_MAC_VOICE` — a layer THIS TARGET leaves out, defined only by `Package.swift`. No
  on-device model (so `VoiceStore.local` is typed `Never?` here — it can only ever be nil), no
  navigation shell, no chat UI. Never use it for an iOS/macOS difference.

`Package.swift` also excludes the phone's page and its pickers, which are built from the app's
design system and its chat/session layers. The voice loop underneath them is shared.

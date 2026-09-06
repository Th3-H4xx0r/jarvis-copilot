# Flutter → SwiftUI port: conventions for every agent

Source app (read-only reference): `~/PranavFiles/coding-projects/jarvis-copilot/mobile_client/lib`
(Flutter tests worth porting: `…/mobile_client/test`). Native Swift already written for the Flutter
shell lives in `…/mobile_client/ios/Runner/*.swift` and `…/mobile_client/ios/JarvisWidget/` — reuse
liberally (copy + adapt), it is the same product.

Target app: this Xcode project (`JarvisWearables.xcodeproj`, single app target, iOS 17+, Swift 5 mode
under the Xcode 26 toolchain, **no third-party packages** — system frameworks only). The port lives
under `JarvisWearables/Copilot/<Area>/…`; tests under `JarvisWearablesTests/<Area>/…`.

## Build & test (the only two commands you need)
```
DD=build/dd-<your-area> scripts/test.sh                 # whole suite on the simulator
DD=build/dd-<your-area> scripts/test.sh MyTests OtherTests   # only these XCTestCase classes
DD=build/dd-<your-area> scripts/build.sh                # compile only
```
Always pass your own `DD=` so parallel agents don't share derived data. Both scripts first run
`scripts/sync-project.rb`, which registers every `*.swift` on disk with the right target —
**never edit `project.pbxproj` by hand and never delete/rename files you don't own.** Just create
files and run the script. Full xcodebuild output is in `$DD/test.log`.

If the build fails in a file that is **not yours** (another agent is mid-edit), wait 90 s and retry
(up to 5 times). Do not "fix" foreign files. If it persists, note it in your report and continue with
what you can.

A project hook ("GateGuard") may refuse your first Bash/Write with a request for "facts". Comply:
state the request in one sentence and what the command produces, then retry.

## Architecture rules
- **Networking:** `JarvisAPI` (`Copilot/Core/JarvisAPI.swift`). `get/post/patch/put/delete/
  postMultipart/bytes` return `APIResponse` (`.object()`, `.array()`, `.decode(T.self)`);
  `streamSSE`, `postSSEOrJSON`, `streamNDJSON` return `AsyncThrowingStream`. Errors are `APIError`;
  `apiErrorMessage(error)` gives the user-facing line. Feature endpoint wrappers are small structs:
  `struct TodosAPI { let api: JarvisAPI; func list() async throws -> [Todo] }`, default
  `api = .shared`. JSON decoding: `JarvisAPI.decoder` (snake_case → camelCase) or the
  `[String: Any]` helpers (`.string/.int/.double/.bool/.dict/.list/.strings`).
- **Tests:** XCTest. `JarvisAPI.mocked()` → `(api, MockTransport)`; `t.enqueue(json:)`,
  `t.enqueueSSE(...)`, `t.route("/api/todos", json: ...)`, inspect `t.lastRequest`, `t.lastBody()`;
  `collect(stream)` gathers an async stream. See `JarvisWearablesTests/Core/TestSupport.swift`.
  Every behaviour you port gets a test **written first (RED), then made GREEN**. Port the matching
  Flutter test file's cases where one exists. Aim for the pure logic (parsers, state machines,
  reducers, policies) to be fully covered; views are exercised through their `@Observable` stores.
- **State:** `@Observable @MainActor final class <Area>Store` owning async work in `Task`s, injected
  dependencies via protocols with production defaults (`init(api: JarvisAPI = .shared, clock: …)`).
  Platform boundaries (audio, camera, location, notifications, clipboard…) go behind small
  protocols (`protocol AudioInput: Sendable`) with a `Default…` implementation and a mock in tests.
  No `ObservableObject`/`@Published` in new code (existing code keeps its own).
- **Views:** SwiftUI, dark-only, tokens from `JcTheme` (`Copilot/UI/JcTheme.swift`, mirrors
  `theme.dart`: `bg`, `bgTop`, `glassFill`, `glassBorder`, `surface`, `surfaceAlt`, `text`, `muted`,
  `accent`, `accentAlt`, `cyan`, `blue`, `primaryBlue`, `success`, `amber`, `slate`, `danger`,
  `brandGradient`). Shared components in `Copilot/UI/` (`AppBackground`, `GlassCard`,
  `GlassIconButton`, `StatusPill`, `GradientButton`, `AsyncView`, `PickerSheet`, `FormSheet`,
  `DetailSheet`). The chat look to copy is `JarvisWearables/Esp32ChatView.swift` (the user's favourite).
- **Persistence:** credentials stay in `Keychain` (see `BridgeClient.swift`); preferences in
  `UserDefaults` behind a `KeyValueStore` protocol (`Copilot/Core/KeyValueStore.swift`) so tests use
  an in-memory one.
- **Naming:** files `<Area><Kind>.swift` (`ChatModels.swift`, `ChatAPI.swift`, `ChatStore.swift`,
  `ChatPage.swift`). Keep each file under ~500 lines; split by responsibility.
- **Concurrency:** structured (`Task`, `async let`, `AsyncThrowingStream`); cancel tasks on
  `deinit`/disappear; hop to `@MainActor` for state mutation.
- **Comments:** explain *why* (server quirks, iOS behaviours), not what.
- Do not touch `firmware/`, the ESP32/bottle/scale code, or `BridgeClient.swift`'s existing
  behaviour (add-only, and only if truly needed).

## Report format (your final message)
1. What you ported (file list with one line each).
2. Test evidence: `scripts/test.sh <YourClasses>` summary lines (executed / failures) — paste real
   output; say plainly if anything fails or was skipped.
3. Deviations from the Flutter behaviour and why.
4. What a follow-up agent must know (open ends, TODOs, interfaces others depend on).

## Wave 2 notes (learned in wave 1 — read before writing code)
- **Use the simulator you were assigned** (`SIM="iPhone 17e" DD=build/dd-x scripts/test.sh …`). Sharing one
  simulator between agents produced "Test crashed with signal kill before establishing connection".
- **`** TEST SUCCEEDED **` alone is not evidence.** Always read the `Executed N tests` line; the script
  now fails a zero-test run, but still quote the count in your report.
- `XCTAssertEqual(try await x(), y)` / `XCTAssertTrue(await …)` do not compile — hoist into a `let`.
- `init(x: Foo = Foo())` fails when `Foo` is `@MainActor`. Use `x: Foo? = nil` and `x ?? Foo()` in the
  body, or `MainActor.assumeIsolated` in a SwiftUI `init`.
- **Name collisions are the main hazard.** Even a file-scope `private` type reserves its name module-wide
  (`DetailRow`, `waitUntil`, `PendingAttachment`, `SpeechSynthesizing` all collided). Grep the tree before
  naming a new type or free function; prefix test helpers with your area (`chatWaitUntil`).
- Stores from wave 1 are `@Observable @MainActor`; construct them in views with `@State private var
  store: XStore` + `init` or `.task`; never in `body`. Every tab stays alive in the shell — gate polling on
  `@Environment(AppRouter.self).selectedTab` and `scenePhase`.
- `MoreTone` (Copilot/More/MoreSupport.swift) → colour: add ONE `Color(tone:)` extension in
  `Copilot/UI/MoreTone+Color.swift` (the More-A agent owns this file; others use it).
- Components: `AppBackground`, `.jcScreen(_:)`, `GlassCard/Group/Row/IconButton/Button/CircleIcon`,
  `GradientButton`, `BlueButton`, `StatusPill`, `StatusBadge`, `AsyncView`/`AsyncLoad`, `CenteredMessage`,
  `PickerSheet/PickerField`, `FormSheet` + `FormTextField/Dropdown/Toggle/ChipMulti`, `DetailSheet` +
  `DetailSheetRow`, `PlaceholderPage`, `WebViewPage(title:path:)`, `JcText.*`, `JcTheme.*`.
- To replace a tab root overwrite `Copilot/<Area>/<Area>Page.swift`; to land a More page change exactly
  one case in `MorePage.destination(for:)` and flip `isPlaceholder` in `MoreDestination.swift`.

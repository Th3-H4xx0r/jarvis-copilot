import Flutter
import UIKit

// MARK: - OnDeviceAIPlugin
//
// Native side of the on-device-AI feature. Bridges the Dart MethodChannel
// `jarviscopilot/ondevice-ai` (+ EventChannel `…/stream`) to the two engines
// (`AppleFMEngine`, `MLXEngine`) and `ModelManager`.
//
// ─── WIRING (one-time, by hand in Xcode) ─────────────────────────────────
//
// 1. Add these files to the Runner target (drag the OnDeviceAI folder into
//    the Xcode project navigator, "Create groups", check "Runner").
//
// 2. Add Swift Packages (File ▸ Add Package Dependencies…):
//        • https://github.com/ml-explore/mlx-swift            → MLX, MLXNN, …
//        • https://github.com/ml-explore/mlx-swift-examples   → MLXLLM, MLXLMCommon
//        • https://github.com/huggingface/swift-transformers  → Transformers/Hub
//
// 3. Capabilities: enable Apple Intelligence / FoundationModels — set the
//    deployment requirements and add the FoundationModels framework
//    (Target ▸ Frameworks/Libraries, or it links automatically when imported
//    on an iOS 26 SDK). No special entitlement is needed for SystemLanguageModel,
//    but the device must have Apple Intelligence enabled.
//
// 4. Paste these TWO lines into AppDelegate's
//    application(_:didFinishLaunchingWithOptions:), after the
//    FlutterViewController is available (`controller` below):
//
//        let controller = window.rootViewController as! FlutterViewController
//        OnDeviceAIPlugin.register(messenger: controller.binaryMessenger)
//
//    (If a `controller` is already in scope from earlier channel
//    registrations, just use that one and add only the second line.)
//
// Until wired, every file here is inert drop-in source — it compiles behind
// the FoundationModels/MLXLLM availability guards but isn't reached.

final class OnDeviceAIPlugin: NSObject {

    // MARK: Channels

    private static let methodChannelName = "jarviscopilot/ondevice-ai"
    private static let eventChannelName  = "jarviscopilot/ondevice-ai/stream"

    /// Held for the app lifetime so the channels' handlers stay alive.
    private static var shared: OnDeviceAIPlugin?

    private let methodChannel: FlutterMethodChannel
    private let streamHandler = OnDeviceStreamHandler()

    // MARK: Engines

    /// Default engine — Apple FM. Swapped to a loaded MLXEngine when the Dart
    /// side loads a non-`apple-fm` model.
    private var appleEngine: OnDeviceEngine = AppleFMEngine()
    private var mlxEngine = MLXEngine()

    /// The engine the next `generate`/`route` will use. Mirrors which model the
    /// Dart side last `loadModel`-ed.
    private var activeEngine: OnDeviceEngine

    /// Serializes inference so one in-flight request can be cancelled cleanly.
    private var inferenceTask: Task<Void, Never>?

    // MARK: Registration

    /// Create the channels and wire the handlers. Call once from AppDelegate.
    static func register(messenger: FlutterBinaryMessenger) {
        let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        let event = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        let plugin = OnDeviceAIPlugin(methodChannel: method)
        event.setStreamHandler(plugin.streamHandler)
        method.setMethodCallHandler { [weak plugin] call, result in
            plugin?.handle(call, result: result)
        }
        // Evict the resident model on memory pressure.
        NotificationCenter.default.addObserver(
            plugin, selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        ModelManager.shared.evictionHook = { [weak plugin] in
            plugin?.unloadLocked()
        }
        shared = plugin
    }

    private init(methodChannel: FlutterMethodChannel) {
        self.methodChannel = methodChannel
        self.activeEngine = appleEngine
        super.init()
    }

    @objc private func onMemoryWarning() {
        ModelManager.shared.handleMemoryWarning()
    }

    // MARK: Dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "availability":
            result(availabilityPayload())

        case "listModels":
            result(ModelManager.shared.listModels())

        case "downloadModel":
            guard let id = args["id"] as? String else { return Self.badArgs(result) }
            downloadModel(id: id)
            result(nil)

        case "cancelDownload":
            guard let id = args["id"] as? String else { return Self.badArgs(result) }
            ModelManager.shared.cancelDownload(modelId: id)
            result(nil)

        case "deleteModel":
            guard let id = args["id"] as? String else { return Self.badArgs(result) }
            result(ModelManager.shared.delete(modelId: id))

        case "loadModel":
            guard let id = args["id"] as? String else { return Self.badArgs(result) }
            loadModel(id: id, result: result)

        case "unloadModel":
            unloadLocked()
            result(nil)

        case "route":
            route(args: args, result: result)

        case "generate":
            generate(args: args, result: result)

        case "cancel":
            cancelInference()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func badArgs(_ result: FlutterResult) {
        result(FlutterError(code: "bad_args", message: "missing required argument", details: nil))
    }

    // MARK: availability

    private func availabilityPayload() -> [String: Any] {
        // Report on the *active* engine; the active engine is Apple FM by
        // default and switches to MLX once a model is loaded.
        let avail = activeEngine.availability()
        switch avail {
        case .available:
            return ["available": true, "engine": activeEngine.id, "reason": NSNull()]
        case .unavailable(let reason):
            // If Apple FM is the active engine and it's unavailable, MLX may
            // still be usable — report that the *feature* is available via MLX
            // when MLX is built, but keep the Apple-FM reason for the UI.
            if activeEngine.id == "apple-fm" {
                if case .available = mlxEngine.availability() {
                    return ["available": true, "engine": "mlx", "reason": reason]
                }
            }
            return ["available": false, "engine": activeEngine.id, "reason": reason]
        }
    }

    // MARK: download

    private func downloadModel(id: String) {
        let sink = streamHandler
        ModelManager.shared.download(
            modelId: id,
            onProgress: { value in
                Self.main { sink.send(["requestId": id, "type": "progress", "value": value]) }
            },
            onDone: {
                Self.main { sink.send(["requestId": id, "type": "done"]) }
            },
            onError: { msg in
                Self.main { sink.send(["requestId": id, "type": "error", "text": msg]) }
            })
    }

    // MARK: load / unload

    private func loadModel(id: String, result: @escaping FlutterResult) {
        // Pick the engine for this model. Apple FM → appleEngine; everything
        // else → MLX. Then become the active engine.
        let engine: OnDeviceEngine = (id == ModelManager.appleFMId) ? appleEngine : mlxEngine

        inferenceTask?.cancel()
        inferenceTask = Task {
            do {
                // Enforce the single-loaded-model guard: unload the previous
                // engine if a different model was resident.
                if let previous = ModelManager.shared.markLoaded(id), previous != id {
                    appleEngine.cancel()
                    mlxEngine.cancel()
                }
                try await engine.load(modelId: id)
                await MainActor.run {
                    self.activeEngine = engine
                    result(true)
                }
            } catch {
                ModelManager.shared.markUnloaded()
                await MainActor.run {
                    result(FlutterError(code: "load_failed",
                                        message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// Unload the resident model and fall back to Apple FM as the active engine.
    private func unloadLocked() {
        inferenceTask?.cancel()
        mlxEngine.cancel()
        appleEngine.cancel()
        ModelManager.shared.markUnloaded()
        activeEngine = appleEngine
    }

    // MARK: route

    private func route(args: [String: Any], result: @escaping FlutterResult) {
        let prompt = args["prompt"] as? String ?? ""
        let system = args["system"] as? String ?? ""
        let schema = args["schema"] as? String ?? ""
        let engine = activeEngine

        inferenceTask?.cancel()
        inferenceTask = Task {
            do {
                let decision = try await engine.route(system: system, prompt: prompt, schemaJSON: schema)
                await MainActor.run { result(decision) }
            } catch is CancellationError {
                await MainActor.run {
                    result(FlutterError(code: "cancelled", message: "cancelled", details: nil))
                }
            } catch {
                // Never hard-fail routing — degrade to escalate so the Dart
                // side can fall back to the cloud model.
                await MainActor.run {
                    result(["action": "escalate", "confidence": 0.0,
                            "toolArgs": [:], "reason": error.localizedDescription])
                }
            }
        }
    }

    // MARK: generate (streaming over the EventChannel)

    private func generate(args: [String: Any], result: @escaping FlutterResult) {
        let requestId = args["requestId"] as? String ?? UUID().uuidString
        let req = GenRequest(
            system: args["system"] as? String ?? "",
            prompt: args["prompt"] as? String ?? "",
            requestId: requestId)
        let engine = activeEngine
        let sink = streamHandler

        // Ack the call immediately; the actual text arrives as stream events.
        result(["requestId": requestId, "started": true])

        inferenceTask?.cancel()
        inferenceTask = Task {
            do {
                _ = try await engine.generate(req) { delta in
                    Self.main {
                        sink.send(["requestId": requestId, "type": "token", "text": delta])
                    }
                }
                Self.main { sink.send(["requestId": requestId, "type": "done"]) }
            } catch is CancellationError {
                Self.main { sink.send(["requestId": requestId, "type": "done"]) }
            } catch {
                Self.main {
                    sink.send(["requestId": requestId, "type": "error",
                               "text": error.localizedDescription])
                }
            }
        }
    }

    private func cancelInference() {
        inferenceTask?.cancel()
        activeEngine.cancel()
        // Cancel both in case the active pointer changed mid-flight.
        appleEngine.cancel()
        mlxEngine.cancel()
    }

    // MARK: Helpers

    /// Hop to the main thread for any Flutter `result`/`eventSink` touch.
    private static func main(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

// MARK: - EventChannel stream handler
//
// Retains the FlutterEventSink between `onListen`/`onCancel` so `generate` and
// `downloadModel` can push `{requestId, type, …}` events at any time. All sends
// must already be on the main thread (the plugin guarantees that via `main`).

final class OnDeviceStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    /// Emit an event to Dart if a listener is attached; dropped otherwise.
    func send(_ payload: [String: Any]) {
        sink?(payload)
    }
}

import Foundation
import Combine
import Network
import NetworkExtension

@MainActor
final class InmoMediaTransfer: ObservableObject {
    static let shared = InmoMediaTransfer()
    @Published private(set) var items: [InmoMediaItem] = []
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "Refresh to read the glasses media inventory."
    @Published private(set) var lastError: String?
    @Published private(set) var completedURLs: [URL] = []
    /// Session evidence only; user-configurable because firmware may use another subnet.
    @Published var serverAddress = "192.168.40.1"
    private var ssid = ""
    private var password = ""
    private var observer: UUID?
    private var revision = 0
    private var wifiRevision = 0
    private var wifiOpen = false
    private var generation = UUID()
    private var connection: NWConnection?
    private var joinedSSID: String?
    private var cancelJoin: (() -> Void)?
    private var deadline: Task<Void, Never>?

    private init() {
        observer = InmoSession.shared.addEventObserver { [weak self] event in
            if case let .message(_, fields, _) = event { self?.receive(fields) }
        }
    }
    private func receive(_ fields: [InmoWireField]) {
        guard let status = try? fields.firstField(20)?.nested() else { return }
        if let control = try? status.firstField(5)?.nested() {
            wifiOpen = (control.firstField(1)?.varint ?? 0) == 0
            wifiRevision += 1
        }
        guard let wifi = try? status.firstField(4)?.nested() else { return }
        let network = wifi.firstField(1)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let secret = wifi.firstField(2)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var list: [InmoMediaItem] = []
        for field in wifi where field.number == 4 {
            guard let info = try? field.nested(),
                  let name = info.firstField(3)?.bytes.flatMap({ String(data: $0, encoding: .utf8) }),
                  let directory = info.firstField(4)?.bytes.flatMap({ String(data: $0, encoding: .utf8) }),
                  let rawSize = info.firstField(5)?.varint, rawSize <= UInt64(Int.max) else { continue }
            let item = InmoMediaItem(name: name, directory: directory, size: Int(rawSize))
            if (try? item.validate()) != nil { list.append(item) }
        }
        ssid = network; password = secret
        items = Array(Dictionary(grouping: list, by: \.id).compactMap { $0.value.first }).sorted { $0.name < $1.name }
        revision += 1
        statusText = "\(items.count) files on glasses. Videos may include separate audio and motion files."
    }
    func refresh() async throws {
        guard !busy else { throw InmoMediaError(message: "Finish or cancel the current download first.") }
        let previous = revision
        try await InmoSession.shared.ensureConnected()
        try await InmoSession.shared.send(InmoCommand.mediaInventory())
        let end = Date().addingTimeInterval(10)
        while revision == previous, Date() < end {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard revision != previous else { throw InmoMediaError(message: "The glasses did not return a media inventory. Reconnect and refresh.") }
    }
    func cancel() {
        guard busy else { return }
        generation = UUID()
        connection?.cancel()
        cancelJoin?()
        statusText = "Cancelling download…"
    }
    func snapshot() -> [String: Any] {
        ["busy": busy, "progress": progress, "status": statusText,
         "files": items.map { ["id": $0.id, "name": $0.name, "bytes": $0.size, "group": $0.group] as [String: Any] },
         "completed_files": completedURLs.map(\.lastPathComponent),
         "export_processing": "Original files; separate Opus audio and motion data are preserved. Video muxing and stabilization are not verified."]
    }
    func download(id: String) async throws -> URL {
        guard !busy else { throw InmoMediaError(message: "Another media download is running.") }
        guard let item = items.first(where: { $0.id == id }) else { throw InmoMediaError(message: "Refresh media and choose an existing file.") }
        guard !ssid.isEmpty else { throw InmoMediaError(message: "The glasses did not supply Wi-Fi credentials. Refresh media first.") }
        let components = serverAddress.split(separator: ".", omittingEmptySubsequences: false)
        let address = components.compactMap { UInt8($0) }
        guard components.count == 4, address.count == 4, address[0] == 192, address[1] == 168 else {
            throw InmoMediaError(message: "Use the glasses' local 192.168.x.x Wi-Fi address.")
        }
        busy = true; progress = 0; lastError = nil
        generation = UUID(); let token = generation
        defer { busy = false; connection?.cancel(); connection = nil; deadline?.cancel(); deadline = nil }
        do {
            let priorWiFi = wifiRevision
            try await InmoSession.shared.send(InmoCommand.wifi(open: true))
            let wifiDeadline = Date().addingTimeInterval(10)
            while wifiRevision == priorWiFi, Date() < wifiDeadline {
                try check(token)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard wifiRevision != priorWiFi, wifiOpen else { throw InmoMediaError(message: "The glasses did not confirm Wi-Fi startup.") }
            statusText = "Joining glasses Wi-Fi…"
            let config = password.isEmpty ? NEHotspotConfiguration(ssid: ssid) : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
            config.joinOnce = true
            try await join(config)
            joinedSSID = ssid
            try check(token)
            let network = NWConnection(host: NWEndpoint.Host(serverAddress), port: 10000, using: .tcp)
            connection = network
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                self?.connection?.cancel()
            }
            try await connect(network)
            try check(token)
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("INMOMedia", isDirectory: true)
            let sink = try InmoMediaFileSink(item: item, directory: root)
            try await send(try InmoMediaFrame(id: 1, payload: Data(item.remotePath.utf8)).encoded(), on: network)
            var parser = InmoMediaFrameParser()
            var accepted = false, digestSent = false, confirmed = false
            while !confirmed {
                try check(token)
                let bytes = try await receive(network)
                for frame in try parser.append(bytes) {
                    guard frame.main == 0 else { throw InmoMediaError(message: "Unexpected media response.") }
                    switch frame.sub {
                    case 1:
                        guard !accepted, frame.payload.isEmpty else { throw InmoMediaError(message: "Invalid media acceptance.") }
                        accepted = true; statusText = "Downloading \(item.name)…"
                    case 0:
                        guard accepted else { throw InmoMediaError(message: "Unexpected media data.") }
                        try sink.append(frame)
                        progress = Double(sink.bytesWritten) / Double(item.size)
                        if sink.complete, !digestSent {
                            try await send(try InmoMediaFrame(id: 2, sub: 0x30, payload: sink.checksum()).encoded(), on: network)
                            digestSent = true; statusText = "Verifying \(item.name)…"
                        }
                    case 0x31:
                        guard digestSent, frame.payload.isEmpty else { throw InmoMediaError(message: "Unexpected media confirmation.") }
                        confirmed = true
                    case 2: throw InmoMediaError(message: "The file is no longer available on the glasses. Refresh media.")
                    default: throw InmoMediaError(message: "The glasses rejected the media transfer.")
                    }
                }
            }
            try check(token)
            let url = try sink.publish(to: root)
            completedURLs.append(url)
            statusText = "Verified and saved \(item.name)."
            await cleanupWiFi()
            return url
        } catch {
            lastError = error.localizedDescription
            statusText = generation == token ? "Download failed. The incomplete file was discarded." : "Download cancelled."
            await cleanupWiFi()
            throw error
        }
    }
    private func join(_ config: NEHotspotConfiguration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var pending: CheckedContinuation<Void, Error>? = continuation
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    pending?.resume(throwing: InmoMediaError(message: "Wi-Fi join timed out. Keep Jarvis open and retry."))
                    pending = nil; self?.cancelJoin = nil
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: config.ssid)
                }
                cancelJoin = {
                    timeout.cancel()
                    pending?.resume(throwing: CancellationError()); pending = nil
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: config.ssid)
                }
                NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
                    Task { @MainActor in
                        timeout.cancel()
                        guard let continuation = pending else {
                            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: config.ssid)
                            return
                        }
                        pending = nil; self?.cancelJoin = nil
                        if let error = error as NSError?, error.code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                            continuation.resume(throwing: error)
                        } else { continuation.resume() }
                    }
                }
            }
        } onCancel: { Task { @MainActor in self.cancelJoin?(); self.cancelJoin = nil } }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func cleanupWiFi() async {
        if let joinedSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: joinedSSID) }
        joinedSSID = nil
        try? await InmoSession.shared.send(InmoCommand.wifi(open: false))
    }
    private func connect(_ network: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var pending: CheckedContinuation<Void, Error>? = continuation
                network.stateUpdateHandler = { state in
                    // All callbacks are serialized on the main queue.
                    switch state {
                    case .ready: pending?.resume(); pending = nil
                    case .failed(let error): pending?.resume(throwing: error); pending = nil
                    case .cancelled: pending?.resume(throwing: CancellationError()); pending = nil
                    default: break
                    }
                }
                network.start(queue: .main)
            }
        } onCancel: { network.cancel() }
    }
    private func send(_ data: Data, on network: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                network.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { network.cancel() }
    }
    private func receive(_ network: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                network.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: InmoMediaError(message: complete ? "The glasses closed the transfer before completion." : "No media data received.")) }
                }
            }
        } onCancel: { network.cancel() }
    }
}

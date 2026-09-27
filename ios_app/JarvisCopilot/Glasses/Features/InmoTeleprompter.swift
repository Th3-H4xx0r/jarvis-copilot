import CryptoKit
import Foundation

extension InmoCommand {
    static func teleprompterUpload(text: String, title: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 32768, !title.isEmpty, title.utf8.count <= 200 else { throw DeviceError.badArgument("Document needs 1–32768 UTF-8 bytes and a 1–200-byte title") }
        let original = Data(text.utf8)
        let checksum = Insecure.MD5.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let document = InmoWireCodec.string(1, title) + InmoWireCodec.bytes(2, original + Data([10])) + InmoWireCodec.string(3, checksum)
        return envelope(type: 9, field: 12, payload: InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(2, document))
    }
    static func teleprompterStart() -> Data {
        envelope(type: 9, field: 12, payload: InmoWireCodec.uint(1, 3) + InmoWireCodec.bytes(4, InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(3, 1)))
    }
    static func teleprompterPage(next: Bool) -> Data { envelope(type: 9, field: 12, payload: InmoWireCodec.uint(9, next ? 1 : 0, includeZero: true)) }
    static func teleprompterProgress(line: Int, percent: Float? = nil) throws -> Data {
        guard (1...100000).contains(line) else { throw DeviceError.badArgument("line must be 1–100000") }
        if let percent, !percent.isFinite || !(0...100).contains(percent) { throw DeviceError.badArgument("percent must be 0–100") }
        return envelope(type: 9, field: 12, payload: InmoWireCodec.uint(1, 6) + InmoWireCodec.bytes(6, InmoWireCodec.uint(1, UInt64(line)) + (percent.map { $0 == 0 ? Data() : InmoWireCodec.float(2, $0) } ?? Data())))
    }
}

@MainActor
final class InmoTeleprompter {
    static let shared = InmoTeleprompter()
    private let session = InmoSession.shared
    private var observer: UUID?
    private var uploadState: Bool?
    private var uploading = false
    private var connectionGeneration = UUID()
    private(set) var documentReady = false
    private(set) var line: Int?
    private(set) var progress: Float?
    init() {
        observer = session.addEventObserver { [weak self] event in
            guard let self else { return }
            if case .connectionChanged = event { self.connectionGeneration = UUID(); self.documentReady = false; self.uploadState = nil; return }
            guard case let .message(type, fields, _) = event, type == 9,
                  let prompt = try? fields.firstField(12)?.nested() else { return }
            if prompt.firstField(1)?.varint == 2, let response = try? prompt.firstField(3)?.nested() {
                self.uploadState = response.firstField(1)?.varint == 1
            }
            if let position = try? prompt.firstField(6)?.nested() {
                let rawLine = position.firstField(1)?.varint ?? 0
                if rawLine <= UInt64(Int.max) { self.line = Int(rawLine) }
                self.progress = position.firstField(2)?.fixed.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) } ?? 0
            }
        }
    }
    func install(on device: InmoGo3Device) {
        for name in ["glasses_teleprompter_upload", "glasses_teleprompter_start", "glasses_teleprompter_page", "glasses_teleprompter_progress", "glasses_teleprompter_stop"] {
            device.featureHandlers[name] = { [weak self] args in
                guard let self else { throw InmoProtocolError.cancelled }
                return try await self.invoke(name, args: args)
            }
        }
    }
    private func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "glasses_teleprompter_upload":
            guard !uploading else { throw DeviceError.badArgument("Wait for the current upload") }
            guard let text = args["text"] as? String else { throw DeviceError.badArgument("text is required") }
            let bytes = try InmoCommand.teleprompterUpload(text: text, title: args["title"] as? String ?? "Jarvis document")
            let generation = connectionGeneration
            uploading = true; documentReady = false; uploadState = nil
            defer { uploading = false }
            try await session.send(bytes)
            let deadline = Date().addingTimeInterval(12)
            while uploadState == nil, Date() < deadline, session.isReady, generation == connectionGeneration {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            guard session.isReady, generation == connectionGeneration else { throw DeviceError.notConnected }
            guard let uploadState else { throw InmoProtocolError.timedOut }
            guard uploadState else { throw InmoProtocolError.unavailable("Glasses rejected the document; edit it and upload again") }
            documentReady = true
            return ["state": "confirmed", "document_ready": true]
        case "glasses_teleprompter_start":
            guard documentReady else { throw DeviceError.badArgument("Upload a document and wait for its acknowledgement first") }
            try await session.send(InmoCommand.teleprompterStart())
        case "glasses_teleprompter_page":
            guard let direction = args["direction"] as? String, ["previous", "next"].contains(direction) else { throw DeviceError.badArgument("direction must be previous or next") }
            try await session.send(InmoCommand.teleprompterPage(next: direction == "next"))
        case "glasses_teleprompter_progress":
            guard let line = args["line"] as? Int else { throw DeviceError.badArgument("line is required") }
            try await session.send(InmoCommand.teleprompterProgress(line: line, percent: (args["percent"] as? NSNumber).map { $0.floatValue }))
        case "glasses_teleprompter_stop": try await session.send(InmoCommand.closeModule(2)); documentReady = false
        default: throw DeviceError.unknownCommand(name)
        }
        return ["state": "sent", "confirmed": false, "line": line as Any? ?? NSNull(), "progress_percent": progress as Any? ?? NSNull()]
    }
}

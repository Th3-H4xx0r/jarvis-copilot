import Foundation

/// Novatek cameras: `/?custom=1&cmd=NNNN` with XML replies (protocol.md §4). Listing,
/// download, time, recording and lock are driven; GPS only from a listed `GPSPATH` file.
struct NovatekCamera: DashcamCamera {
    let family = DashcamFamily.novatek
    let http: DashcamHTTP

    @discardableResult
    func cmd(_ n: Int, _ params: [(String, String)] = [], timeout: TimeInterval = 6) async throws -> NovatekXML.Node {
        let query = params.map { "&\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }.joined()
        let root = try NovatekXML.parse(try await http.get("/?custom=1&cmd=\(n)" + query, timeout: timeout))
        if let status = root.first("Status")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty, status != "0" {
            throw DashcamError.camera("cmd \(n) status \(status)")
        }
        return root
    }

    func info() async throws -> DashcamCameraInfo {
        let root = try await cmd(3029)
        let id = root.first("String")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fw = (try? await cmd(3012))?.first("String")?.text ?? ""
        return DashcamCameraInfo(id: id.isEmpty ? "novatek" : id, family: .novatek, firmware: fw)
    }

    func files(tzOffset: Int) async throws -> [DashcamFile] {
        NovatekCamera.parseFileList(try await cmd(3015, timeout: 15), tzOffset: tzOffset)
    }

    static func parseFileList(_ root: NovatekXML.Node, tzOffset: Int) -> [DashcamFile] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: tzOffset) ?? .current
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return root.all("File").compactMap { node in
            let fpath = node.first("FPATH")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !fpath.isEmpty else { return nil }
            var path = fpath
            if let colon = path.firstIndex(of: ":"), path.distance(from: path.startIndex, to: colon) <= 2 {
                path = String(path[path.index(after: colon)...])
            }
            path = path.replacingOccurrences(of: "\\", with: "/")
            let size = Int64(node.first("SIZE")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let attr = Int(node.first("ATTR")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0", radix: 16) ?? 0
            let startText = (node.first("TIME_START") ?? node.first("TIME"))?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let start = f.date(from: startText) ?? Date(timeIntervalSince1970: 0)
            var duration = 0.0
            if let stop = node.first("TIME_STOP").flatMap({ f.date(from: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                duration = max(0, stop.timeIntervalSince(start))
            }
            let upper = path.uppercased()
            let photo = upper.hasSuffix(".JPG") || upper.hasSuffix(".JPEG") || upper.contains("/PHOTO/")
            let locked = attr & 1 == 1 || upper.contains("/RO/") || upper.contains("/EMR/")
            let kind: DashcamClipKind = photo ? .photo : locked ? .event : upper.contains("/PARK") ? .parking : .normal
            let gps = node.first("GPSPATH")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return DashcamFile(path: path, kind: kind, lens: ViidureCamera.lens(fromPath: path), start: start,
                               durationS: duration, size: size, locked: locked,
                               gpsPath: (gps?.isEmpty ?? true) ? nil : gps)
        }
    }

    func thumbnailURL(_ file: DashcamFile) -> URL? {
        URL(string: http.url(file.path).absoluteString + "?custom=1&cmd=4001")
    }

    func setTime(_ date: Date, timeZone: TimeZone) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        try await cmd(3005, [("str", f.string(from: date))])
        f.dateFormat = "HH:mm:ss"
        try await cmd(3006, [("str", f.string(from: date))])
    }

    func isRecording() async throws -> Bool {
        let v = try await cmd(2016).first("Value")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return !(v.isEmpty || v == "0")
    }

    func setRecording(_ on: Bool) async throws { try await cmd(2001, [("par", on ? "1" : "0")]) }
    func lock() async throws { try await cmd(9133, [("par", "1")]) }

    func snapshot() async throws -> String? {
        let root = try await cmd(1001, timeout: 10)
        return root.first("FPATH")?.text.replacingOccurrences(of: "\\", with: "/")
    }

    func settings() async throws -> [DashcamSettingItem] {
        // 3014 lists every setting as <Cmd>/<Status> pairs; the option names live in the app, not the camera.
        let root = try await cmd(3014)
        var out: [DashcamSettingItem] = []
        var pendingCmd: String?
        for node in root.children {
            if node.name == "Cmd" { pendingCmd = node.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if node.name == "Status", let c = pendingCmd {
                out.append(DashcamSettingItem(name: c, value: node.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                pendingCmd = nil
            }
        }
        return out
    }

    func set(_ name: String, _ value: String) async throws {
        guard let n = Int(name) else { throw DashcamError.unsupported("Novatek settings are numbered commands") }
        try await cmd(n, [("par", value)])
    }

    func sdInfo() async throws -> DashcamSDInfo {
        let v = try await cmd(3024).first("Value")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let free = (try? await cmd(3017))?.first("Value")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DashcamSDInfo(ok: v == "1", totalBytes: nil, freeBytes: free.flatMap { Int64($0) })
    }

    func format() async throws { try await cmd(3010, [("par", "1")], timeout: 30) }
    func delete(_ file: DashcamFile) async throws { try await cmd(4003, [("str", "A:" + file.path.replacingOccurrences(of: "/", with: "\\"))]) }

    func setWiFi(ssid: String?, password: String?) async throws {
        if let ssid, !ssid.isEmpty { try await cmd(3003, [("str", ssid)]) }
        if let password, !password.isEmpty { try await cmd(3004, [("str", password)]) }
    }

    func playback(_ enter: Bool) async throws {}

    func gps(_ file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix] {
        guard let gpsPath = file.gpsPath else { return [] }
        let data = try await http.get(gpsPath, timeout: 10)
        return DashcamGPS.align(DashcamGPS.parseText(data), clipStart: file.start, duration: file.durationS, tzOffset: tzOffset)
    }
}

/// A tiny DOM over `XMLParser`, enough for Novatek's flat replies.
enum NovatekXML {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(name: String) { self.name = name }

        func first(_ tag: String) -> Node? {
            for c in children {
                if c.name == tag { return c }
                if let hit = c.first(tag) { return hit }
            }
            return nil
        }

        func all(_ tag: String) -> [Node] {
            children.flatMap { ($0.name == tag ? [$0] : []) + $0.all(tag) }
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = Node(name: "#root")
        var stack: [Node] = []
        override init() { super.init(); stack = [root] }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = Node(name: e); stack.last?.children.append(n); stack.append(n)
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last?.text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }
    }

    static func parse(_ data: Data) throws -> Node {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { throw DashcamError.badReply("not XML") }
        return builder.root
    }
}

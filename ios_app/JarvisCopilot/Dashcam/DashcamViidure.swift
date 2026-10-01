import Foundation

/// Viidure / Eeasy cameras (Peztio, Affver): `/app/<cmd>` with JSON `{"result", "info"}` replies.
struct ViidureCamera: DashcamCamera {
    let family = DashcamFamily.viidure
    let http: DashcamHTTP

    static let folders = ["loop", "park", "event", "emr", "race"]
    static let page = 100

    func call(_ cmd: String, timeout: TimeInterval = 6) async throws -> Any? {
        try ViidureCamera.unwrap(try await http.get("/app/" + cmd, timeout: timeout), cmd: cmd)
    }

    /// `{"result": 0, "info": …}` → info; any other result throws with the camera's message.
    static func unwrap(_ data: Data, cmd: String) throws -> Any? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DashcamError.badReply("\(cmd) is not JSON")
        }
        let result = (obj["result"] as? NSNumber)?.intValue ?? -1
        guard result == 0 else {
            let message = (obj["info"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "error \(result)"
            throw DashcamError.camera("\(cmd): \(message)")
        }
        return obj["info"]
    }

    func info() async throws -> DashcamCameraInfo {
        let attr = try await call("getdeviceattr") as? [String: Any] ?? [:]
        let product = (try? await call("getproductinfo")) as? [String: Any] ?? [:]
        let media = (try? await call("getmediainfo")) as? [String: Any] ?? [:]
        return ViidureCamera.parseInfo(attr: attr, product: product, media: media)
    }

    static func parseInfo(attr: [String: Any], product: [String: Any], media: [String: Any]) -> DashcamCameraInfo {
        func s(_ d: [String: Any], _ k: String) -> String {
            if let v = d[k] as? String { return v }
            if let n = d[k] as? NSNumber { return n.stringValue }
            return ""
        }
        let id = [s(attr, "uuid"), s(attr, "imei"), s(attr, "bssid")].first { !$0.isEmpty } ?? ""
        return DashcamCameraInfo(
            id: id, family: .viidure,
            model: s(product, "model"),
            brand: [s(product, "sp"), s(product, "company")].first { !$0.isEmpty } ?? "",
            soc: s(product, "soc"),
            firmware: s(attr, "softver"),
            lenses: max(1, (attr["camnum"] as? NSNumber)?.intValue ?? 1),
            autorecord: (media["autorecord"] as? NSNumber)?.intValue == 1)
    }

    func files(tzOffset: Int) async throws -> [DashcamFile] {
        var out: [DashcamFile] = []
        var anyAnswered = false
        var lastError: Error?
        for folder in ViidureCamera.folders {
            var start = 0
            var seen = Set<String>()
            while true {
                let info: Any?
                do {
                    info = try await call("getfilelist?folder=\(folder)&start=\(start)&end=\(start + ViidureCamera.page - 1)", timeout: 10)
                    anyAnswered = true
                } catch DashcamError.camera(let m) {
                    lastError = DashcamError.camera(m)
                    break   // an empty or unknown folder answers with an error on some firmware
                }
                let pageFiles = ViidureCamera.parseFileList(info, tzOffset: tzOffset)
                let fresh = pageFiles.filter { !seen.contains($0.path) }
                if fresh.isEmpty { break }
                fresh.forEach { seen.insert($0.path) }
                out += fresh
                if pageFiles.count < ViidureCamera.page { break }
                start += ViidureCamera.page
            }
        }
        if !anyAnswered, let lastError { throw lastError }
        return out
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    /// `getfilelist` info → files (protocol.md §3).
    static func parseFileList(_ info: Any?, tzOffset: Int) -> [DashcamFile] {
        guard let folders = info as? [[String: Any]] else { return [] }
        let stamps = stampFormat
        stamps.timeZone = TimeZone(secondsFromGMT: tzOffset) ?? .current
        var out: [DashcamFile] = []
        for folder in folders {
            let name = (folder["folder"] as? String ?? "").lowercased()
            for item in folder["files"] as? [[String: Any]] ?? [] {
                guard let path = item["name"] as? String, !path.isEmpty else { continue }
                let sizeKB = (item["size"] as? NSNumber)?.int64Value ?? Int64(item["size"] as? String ?? "") ?? 0
                guard sizeKB > 0 else { continue }
                let start: Date
                if let stamp = item["createtimestr"] as? String, stamp.count == 14, let d = stamps.date(from: stamp) {
                    start = d
                } else {
                    let local = (item["createtime"] as? NSNumber)?.doubleValue ?? 0
                    start = Date(timeIntervalSince1970: local - Double(tzOffset))
                }
                let video = (item["type"] as? NSNumber)?.intValue == 2
                let kind: DashcamClipKind = !video ? .photo : {
                    switch name {
                    case "park": return .parking
                    case "event", "emr": return .event
                    default: return .normal
                    }
                }()
                out.append(DashcamFile(
                    path: path, kind: kind, lens: lens(fromPath: path), start: start,
                    durationS: video ? (item["duration"] as? NSNumber)?.doubleValue ?? 0 : 0,
                    size: sizeKB * 1024, locked: name == "emr", folder: name,
                    gpsPath: (item["GPSPATH"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        return out
    }

    static func lens(fromPath path: String) -> DashcamLens {
        let low = path.lowercased()
        let stem = (low.split(separator: "/").last.map(String.init) ?? low).split(separator: ".").first.map(String.init) ?? low
        if stem.hasSuffix("_r") || stem.hasSuffix("-r") || low.contains("/rear") || low.contains("video_rear") || low.contains("/r/") {
            return .rear
        }
        if stem.hasSuffix("_i") || stem.hasSuffix("-i") || low.contains("/inside") || low.contains("/in/") {
            return .inside
        }
        return .front
    }

    func thumbnailURL(_ file: DashcamFile) -> URL? {
        let q = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        return URL(string: http.base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                   + "/app/getthumbnail?file=" + q)
    }

    func setTime(_ date: Date, timeZone: TimeZone) async throws {
        let offset = timeZone.secondsFromGMT(for: date)
        _ = try? await call("settimezone?timezone=\(Int((Double(offset) / 3600).rounded()))")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMddHHmmss"
        _ = try await call("setsystime?date=" + f.string(from: date))
    }

    func isRecording() async throws -> Bool {
        ViidureCamera.value(try await call("getparamvalue?param=rec"), name: "rec") == "1"
    }

    static func value(_ info: Any?, name: String) -> String? {
        func str(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        if let d = info as? [String: Any] { return str(d["value"]) ?? str(d[name]) }
        if let a = info as? [[String: Any]] {
            return a.first { ($0["name"] as? String) == name }.flatMap { str($0["value"]) }
        }
        return str(info)
    }

    func setRecording(_ on: Bool) async throws { _ = try await call("setparamvalue?param=rec&value=\(on ? 1 : 0)") }
    func lock() async throws { _ = try await call("lockvideo") }

    func snapshot() async throws -> String? {
        let info = try await call("snapshot", timeout: 10)
        return (info as? [String: Any])?["name"] as? String
    }

    func settings() async throws -> [DashcamSettingItem] {
        ViidureCamera.mergeSettings(items: try await call("getparamitems?param=all"),
                                    values: try await call("getparamvalue?param=all"))
    }

    static func mergeSettings(items: Any?, values: Any?) -> [DashcamSettingItem] {
        var current: [String: String] = [:]
        for v in values as? [[String: Any]] ?? [] {
            guard let n = v["name"] as? String else { continue }
            current[n] = value(v, name: n)
        }
        var out: [DashcamSettingItem] = []
        for it in items as? [[String: Any]] ?? [] {
            guard let name = it["name"] as? String, !name.isEmpty else { continue }
            let codes = (it["index"] as? [Any] ?? []).map { "\($0)" }
            let labels = (it["items"] as? [Any] ?? []).map { "\($0)" }
            let options = codes.enumerated().map { i, c in
                DashcamSettingItem.Option(code: c, label: i < labels.count ? labels[i] : c)
            }
            out.append(DashcamSettingItem(name: name, value: current[name], options: options,
                                          range: (it["range"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
        }
        for (name, v) in current.sorted(by: { $0.key < $1.key }) where !out.contains(where: { $0.name == name }) {
            out.append(DashcamSettingItem(name: name, value: v))
        }
        return out
    }

    func set(_ name: String, _ value: String) async throws {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        _ = try await call("setparamvalue?param=\(n)&value=\(v)")
    }

    func sdInfo() async throws -> DashcamSDInfo {
        let d = try await call("getsdinfo") as? [String: Any] ?? [:]
        let status = (d["status"] as? NSNumber)?.intValue ?? -1
        guard status == 0 else { return DashcamSDInfo(ok: false) }
        return DashcamSDInfo(ok: true,
                             totalBytes: ((d["total"] as? NSNumber)?.int64Value).map { $0 * 1_048_576 },
                             freeBytes: ((d["free"] as? NSNumber)?.int64Value).map { $0 * 1_048_576 })
    }

    func format() async throws { _ = try await call("sdformat?index=0", timeout: 30) }

    func delete(_ file: DashcamFile) async throws {
        _ = try await call("deletefile?file=" + (file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path))
    }

    func setWiFi(ssid: String?, password: String?) async throws {
        if let ssid, !ssid.isEmpty {
            _ = try await call("setwifi?wifissid=" + (ssid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ssid))
        }
        if let password, !password.isEmpty {
            _ = try await call("setwifi?wifipwd=" + (password.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? password))
        }
    }

    func playback(_ enter: Bool) async throws { _ = try await call("playback?param=\(enter ? "enter" : "exit")") }

    func gps(_ file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix] {
        if let gpsPath = file.gpsPath {
            let data = try await http.get(gpsPath, timeout: 10)
            return DashcamGPS.align(DashcamGPS.parseText(data), clipStart: file.start, duration: file.durationS, tzOffset: tzOffset)
        }
        return try await DashcamGPS.fetch(http: http, file: file, tzOffset: tzOffset)
    }
}

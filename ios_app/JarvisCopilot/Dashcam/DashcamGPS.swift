import Foundation

/// GPS + speed stored at the end of every Viidure video file (protocol.md §5). Reading it costs
/// two small range requests — the clip itself never has to be downloaded.
enum DashcamGPS {
    static let markers: [String] = ["&&&&", "####", "****"]
    static let record = 132
    static let header = 28

    /// The last 8 bytes: marker + big-endian block size.
    static func parseTail(_ last8: Data) -> (marker: String, size: Int)? {
        guard last8.count == 8 else { return nil }
        let bytes = [UInt8](last8)
        let marker = String(decoding: bytes[0..<4], as: UTF8.self)
        guard markers.contains(marker) else { return nil }
        let size = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        return size > 0 && size < 1_024_000 ? (marker, size) : nil
    }

    /// The block (the file's last `size` bytes) → fixes in file order, times as written. MP4 clips wrap it in a
    /// `free` box; the A4's `.ts` clips end with two `SKIP` boxes ("SKIPLIGO" "GPSINFO", `&&&&` then `####`) of the
    /// same 132-byte records, one per second.
    static func parseBlock(_ block: Data, marker: String) -> [DashcamFix] {
        let b = [UInt8](block)
        guard b.count >= header,
              (Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])) == b.count,
              ["free", "SKIP", "skip"].contains(String(decoding: b[4..<8], as: UTF8.self)) else { return [] }
        let fh = b.count >= 10 && b[8] == UInt8(ascii: "F") && b[9] == UInt8(ascii: "H")
        var lines: [String] = []
        if fh {
            var off = header + 64
            while off <= b.count - 136 { lines.append(cString(b, off)); off += record }
        } else {
            var off = header
            while off <= b.count - record { lines.append(cString(b, off + 4)); off += record }
        }
        let scrambled = marker == "****" && !fh
        return lines.compactMap { parseLine($0, scrambled: scrambled) }
    }

    private static func cString(_ b: [UInt8], _ start: Int) -> String {
        var end = start
        let limit = min(b.count, start + record)
        while end < limit, b[end] != 0 { end += 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    static func lineValid(_ line: String) -> Bool {
        let s = Array(line.trimmingCharacters(in: .whitespaces))
        return s.count > 20 && s[0] == "2" && s[1] == "0" && (s[20] == "N" || s[20] == "S")
    }

    /// `N:4152.6800` / `W:08737.8000` / `N:41.878` → signed decimal degrees.
    static func coordinate(_ token: String, latitude: Bool) -> Double? {
        let chars = Array(token)
        guard chars.count >= 3, chars[1] == ":" else { return nil }
        let hemi = chars[0]
        guard latitude ? (hemi == "N" || hemi == "S") : (hemi == "E" || hemi == "W") else { return nil }
        var raw = String(chars[2...])
        guard raw != "-", raw != "NA", !raw.isEmpty else { return nil }
        var negative = hemi == "S" || hemi == "W"
        if raw.hasPrefix("-") { negative.toggle(); raw.removeFirst() }
        guard let value = Double(raw), value.isFinite else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts.first ?? "")
        let degrees: Double
        if whole.count < (latitude ? 3 : 4) {
            degrees = value   // already decimal degrees
        } else {
            let width = latitude ? 4 : 5
            let padded = String(repeating: "0", count: max(0, width - whole.count)) + whole
            let dd = latitude ? 2 : 3
            let deg = Double(padded.prefix(dd)) ?? 0
            let frac = parts.count > 1 ? String(parts[1]) : "0"
            let minutes = Double(String(padded.dropFirst(dd)) + "." + frac) ?? 0
            degrees = deg + minutes / 60
        }
        return negative ? -degrees : degrees
    }

    private static func number(_ token: String, prefix: String = "") -> Double? {
        var t = token
        if !prefix.isEmpty {
            guard t.hasPrefix(prefix) else { return nil }
            t.removeFirst(prefix.count)
        }
        guard t != "-", t != "NA", !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    /// One track line → fix. The time is read as UTC; `align` corrects it if the camera wrote local time.
    static func parseLine(_ line: String, scrambled: Bool = false) -> DashcamFix? {
        guard lineValid(line) else { return nil }
        let tok = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tok.count >= 5,
              let when = lineTime.date(from: tok[0].replacingOccurrences(of: "-", with: "/") + " " + tok[1])
        else { return nil }
        var t = when.timeIntervalSince1970
        if let ms = tok.lazy.compactMap({ number($0, prefix: "MS:") }).first { t += ms / 10 }
        var speed = number(tok[4])
        var lat: Double?, lon: Double?
        if scrambled {
            guard tok[2].count > 2, tok[3].count > 2,
                  let a = Double(tok[2].dropFirst(2)), let b = Double(tok[3].dropFirst(2)) else { return nil }
            let a10 = (a / 10).rounded(.down) * 10, b10 = (b / 10).rounded(.down) * 10
            lat = coordinate(String(tok[2].prefix(2)) + String(format: "%.6f", (b - b10) / 0.8668 + a10), latitude: true)
            lon = coordinate(String(tok[3].prefix(2)) + String(format: "%.6f", b10 + (a - a10) / 0.8668), latitude: false)
            speed = speed.map { $0 * 1.852 }
        } else {
            lat = coordinate(tok[2], latitude: true)
            lon = coordinate(tok[3], latitude: false)
        }
        guard let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon),
              !(abs(lat) < 1e-6 && abs(lon) < 1e-6) else { return nil }
        var heading = tok.dropFirst(5).lazy.compactMap { number($0, prefix: "A:") }.first
        if heading == nil {
            if tok.count >= 19, tok[9].count > 2 { heading = Double(tok[9].dropFirst(2)) }
            else if tok.count == 10, tok[9].contains("H"), tok[8].count > 2 { heading = Double(tok[8].dropFirst(2)) }
        }
        if let h = heading, !(0...360).contains(h) || !h.isFinite { heading = nil }
        let mps: Double? = speed.flatMap { (0...400).contains($0) ? $0 / 3.6 : nil }
        return DashcamFix(t: t, lat: lat, lon: lon, speed: mps, heading: heading)
    }

    /// Line times are wall-clock; keep whichever reading (UTC or camera-local) lands in the clip.
    static func align(_ fixes: [DashcamFix], clipStart: Date, duration: Double, tzOffset: Int) -> [DashcamFix] {
        guard !fixes.isEmpty, tzOffset != 0 else { return fixes }
        let lo = clipStart.timeIntervalSince1970 - 60
        let hi = clipStart.timeIntervalSince1970 + max(duration, 1) + 60
        func inside(_ shift: Double) -> Int { fixes.filter { (lo...hi).contains($0.t - shift) }.count }
        guard inside(Double(tzOffset)) > inside(0) else { return fixes }
        return fixes.map { var f = $0; f.t -= Double(tzOffset); return f }
    }

    /// Reads a clip's GPS straight off the camera: size → tail → block.
    static func fetch(http: DashcamHTTP, file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix] {
        let total = try await http.size(file.path)
        guard total >= 8 else { return [] }
        let tail = try await http.range(file.path, start: total - 8, length: 8)
        guard let (marker, size) = parseTail(tail), Int64(size) <= total else { return [] }
        let block = try await http.range(file.path, start: total - Int64(size), length: size)
        return align(parseBlock(block, marker: marker), clipStart: file.start, duration: file.durationS, tzOffset: tzOffset)
    }

    /// Lines from a GPS text file (`GPSPATH`, day logs).
    static func parseText(_ data: Data) -> [DashcamFix] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }
}

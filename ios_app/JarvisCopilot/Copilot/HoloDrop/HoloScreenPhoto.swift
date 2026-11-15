import CoreGraphics
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Back Tap while looking at a photo: iOS never says which photo another app shows, so find it.
/// The screenshot contains the photo — cut out the photo area (drop the bars and Photos' buttons),
/// hash it, and compare against recent library photos' thumbnails. A confident, unique match
/// means the original goes instead of the screenshot. All on the phone; nothing leaves it.
enum HoloScreenPhoto {

    // MARK: the photo itself

    /// What the Back Tap shortcut's "Get What's On Screen" step handed over, as something to
    /// send — only when it's a photo or video (Photos gives the photo itself, original file and
    /// all). Pages, places and anything else return nil: those go the screenshot way.
    static func onScreenItem(data: Data, filename: String, type: UTType?, in dir: URL) -> HoloItem? {
        guard !data.isEmpty else { return nil }
        return onScreenItem(filename: filename, type: type, in: dir) { try data.write(to: $0) }
    }

    /// The same, copied from a file (a long video never goes through memory).
    static func onScreenItem(file: URL, filename: String, type: UTType?, in dir: URL) -> HoloItem? {
        onScreenItem(filename: filename, type: type, in: dir) { try FileManager.default.copyItem(at: file, to: $0) }
    }

    private static func onScreenItem(filename: String, type: UTType?, in dir: URL,
                                     put: (URL) throws -> Void) -> HoloItem? {
        let ext = (filename as NSString).pathExtension
        guard let type = type ?? UTType(filenameExtension: ext) else { return nil }
        let kind: String
        if type.conforms(to: .image) { kind = "image" }
        else if type.conforms(to: .movie) { kind = "video" }
        else { return nil }
        let fallback = "\(kind == "video" ? "Video" : "Photo").\(type.preferredFilenameExtension ?? (kind == "video" ? "mov" : "jpg"))"
        let name = HoloArrival.safeName(filename, fallback: fallback)
        let url = dir.appendingPathComponent(name)
        guard (try? put(url)) != nil else { return nil }
        return .file(url, name: name, mime: type.preferredMIMEType ?? (kind == "video" ? "video/quicktime" : "image/jpeg"),
                     kind: kind)
    }

    // MARK: the photo inside the screenshot

    /// The photo's rectangle in the screenshot, 0–1, top-left origin: the longest run of rows (then
    /// columns) that differ from the background colour. Nil when nothing photo-like stands out.
    static func photoRegion(in image: CGImage) -> CGRect? {
        let w = 96, h = max(32, Int(Double(image.height) / Double(image.width) * 96))
        guard let px = gray(image, width: w, height: h) else { return nil }
        let corners = [px[0], px[w - 1], px[(h - 1) * w], px[(h - 1) * w + w - 1]].sorted()
        let bg = (Int(corners[1]) + Int(corners[2])) / 2
        func differs(_ v: UInt8) -> Bool { abs(Int(v) - bg) > 14 }
        func longestRun(_ active: [Bool]) -> (Int, Int)? {
            var best: (Int, Int)?, start: Int?
            for (i, a) in (active + [false]).enumerated() {
                if a, start == nil { start = i }
                if !a, let s = start {
                    if best == nil || i - s > best!.1 - best!.0 { best = (s, i) }
                    start = nil
                }
            }
            return best
        }
        let rows = (0..<h).map { y in Double((0..<w).filter { differs(px[y * w + $0]) }.count) / Double(w) > 0.45 }
        guard let (top, bottom) = longestRun(rows), bottom - top >= h / 6 else { return nil }
        let cols = (0..<w).map { x in
            Double((top..<bottom).filter { differs(px[$0 * w + x]) }.count) / Double(bottom - top) > 0.45
        }
        guard let (left, right) = longestRun(cols), right - left >= w / 4 else { return nil }
        return CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                      width: Double(right - left) / Double(w), height: Double(bottom - top) / Double(h))
    }

    // MARK: perceptual hash

    /// 64-bit difference hash (9×8 grey, each pixel brighter than its right neighbour), of
    /// `region` (0–1, top-left) when given.
    static func dHash(_ image: CGImage, region: CGRect? = nil) -> UInt64 {
        var source = image
        if let r = region {
            let rect = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                              width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
            if let cropped = image.cropping(to: rect) { source = cropped }
        }
        guard let px = gray(source, width: 9, height: 8) else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where px[y * 9 + x] > px[y * 9 + x + 1] {
                hash |= 1 << UInt64(y * 8 + x)
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// The candidate to trust: close (≤ 10 of 64 bits) and clearly closer than the runner-up.
    static func pick<ID>(_ scored: [(ID, Int)]) -> ID? {
        let sorted = scored.sorted { $0.1 < $1.1 }
        guard let best = sorted.first, best.1 <= 10 else { return nil }
        if sorted.count > 1, sorted[1].1 - best.1 < 6 { return nil }
        return best.0
    }

    /// Greyscale pixels, top row first.
    static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: width * height)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }

    // MARK: the library

    /// The library photo (or video) shown in `screenshot`, among the most recent `limit`; nil when
    /// none matches confidently (then the screenshot itself goes).
    @MainActor
    static func findOriginal(for screenshot: URL, limit: Int = 300) async -> PHAsset? {
        guard let src = CGImageSourceCreateWithURL(screenshot as CFURL, nil),
              let shot = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let region = photoRegion(in: shot) else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let target = dHash(shot, region: region)
        let aspect = (region.width * CGFloat(shot.width)) / max(1, region.height * CGFloat(shot.height))
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.fetchLimit = limit
        var candidates: [PHAsset] = []
        PHAsset.fetchAssets(with: opts).enumerateObjects { asset, _, _ in
            // A letterboxed photo keeps its shape on screen; one filling the screen may be cropped.
            let a = CGFloat(asset.pixelWidth) / max(1, CGFloat(asset.pixelHeight))
            if abs(a - aspect) / aspect < 0.08 || region.height > 0.9 { candidates.append(asset) }
        }
        var scored: [(PHAsset, Int)] = []
        for asset in candidates.prefix(120) {
            if let thumb = await thumbnail(asset) { scored.append((asset, hamming(target, dHash(thumb)))) }
        }
        return pick(scored)
    }

    /// A small thumbnail at the photo's own shape (aspect-fit, so it hashes like the screenshot crop).
    @MainActor
    private static func thumbnail(_ asset: PHAsset) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 96, height: 96),
                                                  contentMode: .aspectFit, options: opts) { image, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image?.cgImage)
            }
        }
    }
}

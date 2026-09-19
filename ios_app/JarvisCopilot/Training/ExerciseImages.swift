import SwiftUI
import UIKit

/// Exercise photos, fetched from the dataset's repository the first time
/// they are shown and kept on disk after that.
actor ExerciseImageCache {
    static let shared = ExerciseImageCache()

    /// Bounded: scrolling the whole library must not keep every photo.
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        return cache
    }()
    private let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExerciseImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The photo, full size.
    func image(_ path: String) async -> UIImage? {
        if let hit = memory.object(forKey: path as NSString) { return hit }
        let file = folder.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        var image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        if image == nil, let url = ExerciseLibrary.imageURL(path),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200, let fetched = UIImage(data: data) {
            try? data.write(to: file, options: .atomic)
            image = fetched
        }
        if let image { memory.setObject(image, forKey: path as NSString) }
        return image
    }

    /// The photo scaled down for a thumbnail of `side` points.
    func thumbnail(_ path: String, side: CGFloat) async -> UIImage? {
        let key = "\(path)@\(Int(side))" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        guard let full = await image(path) else { return nil }
        let pixels = side * 3
        let scale = pixels / max(1, min(full.size.width, full.size.height))
        let small = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * scale, height: full.size.height * scale)) ?? full
        memory.setObject(small, forKey: key)
        return small
    }
}

/// An exercise's first photo in a rounded square, its equipment's symbol
/// until (or unless) the photo arrives.
struct ExerciseThumbnail: View {
    let exercise: Exercise?
    var size: CGFloat = 44
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.white.opacity(0.9))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(JcTheme.surfaceAlt)
                Image(systemName: exercise?.equipment.symbol ?? "dumbbell.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
        .task(id: exercise?.id) {
            guard let path = exercise?.images.first else { return }
            image = await ExerciseImageCache.shared.thumbnail(path, side: size)
        }
    }
}

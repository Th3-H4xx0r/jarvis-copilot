import SwiftUI
import UIKit

/// Exercise photos, fetched from the dataset's repository the first time
/// they are shown and kept on disk after that.
actor ExerciseImageCache {
    static let shared = ExerciseImageCache()

    private var memory: [String: UIImage] = [:]
    private let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExerciseImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(_ path: String) async -> UIImage? {
        if let hit = memory[path] { return hit }
        let file = folder.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[path] = image
            return image
        }
        guard let url = ExerciseLibrary.imageURL(path),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        memory[path] = image
        return image
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
            image = await ExerciseImageCache.shared.image(path)
        }
    }
}

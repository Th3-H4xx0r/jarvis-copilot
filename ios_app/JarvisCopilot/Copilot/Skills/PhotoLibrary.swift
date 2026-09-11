import Foundation
import UIKit
import Photos
import PhotosUI

// MARK: - Boundary: reading the library without a picker

/// One photo pulled straight from the library (no UI), for "what's my latest
/// photo". `index` 0 = newest.
struct LibraryPhoto: Sendable, Equatable {
    let data: Data
    let mime: String
    let takenAt: Date?
    let width: Int
    let height: Int
    /// Photos the library holds in total, so the skill can say "of 3,412".
    let total: Int
}

protocol PhotoLibraryReading: Sendable {
    /// Prompts for library access on first use. False when denied.
    func requestAuthorization() async throws -> Bool
    /// Nil when the library has fewer than `index + 1` photos.
    func recent(index: Int, maxPixels: Int) async throws -> LibraryPhoto?
}

/// Shrink + re-encode so a photo fits a chat/voice turn: a 48 MP HEIC is
/// tens of megabytes; ~1280 px JPEG is a few hundred KB and plenty for vision.
enum PhotoEncoding {
    static let defaultMaxPixels = 1280
    static let jpegQuality: CGFloat = 0.82

    static func jpeg(_ image: UIImage, maxPixels: Int) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > CGFloat(maxPixels) ? CGFloat(maxPixels) / longest : 1
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: jpegQuality)
    }
}

final class DefaultPhotoLibrary: PhotoLibraryReading {
    func requestAuthorization() async throws -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: break
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func recent(index: Int, maxPixels: Int) async throws -> LibraryPhoto? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = index + 1
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = PHAsset.fetchAssets(with: .image, options: nil).count
        guard assets.count > index else { return nil }
        let asset = assets.object(at: index)
        let image: UIImage = try await withCheckedThrowingContinuation { cont in
            let req = PHImageRequestOptions()
            req.deliveryMode = .highQualityFormat
            req.isNetworkAccessAllowed = true   // iCloud-optimised originals
            req.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixels, height: maxPixels),
                contentMode: .aspectFit,
                options: req
            ) { img, info in
                // High-quality delivery calls back once; guard anyway so a
                // degraded-then-final pair can't resume twice.
                guard !resumed else { return }
                if let img {
                    resumed = true
                    cont.resume(returning: img)
                } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    resumed = true
                    let err = info?[PHImageErrorKey] as? Error
                    cont.resume(throwing: SkillError.failed(err?.localizedDescription ?? "could not load the photo"))
                }
            }
        }
        guard let jpeg = PhotoEncoding.jpeg(image, maxPixels: maxPixels) else {
            throw SkillError.failed("could not encode the photo")
        }
        return LibraryPhoto(data: jpeg, mime: "image/jpeg", takenAt: asset.creationDate,
                            width: asset.pixelWidth, height: asset.pixelHeight, total: total)
    }
}

// MARK: - Boundary: the system pickers (camera / library)

/// `PHPickerViewController` for the library (no permission prompt — the
/// picker runs out of process) and `UIImagePickerController` for the camera.
final class DefaultPhotoPicker: NSObject, PhotoPicking {
    func pick(_ source: PhotoSource) async throws -> CapturedImage? {
        let image: UIImage? = try await MainActor.run {
            guard let top = TopViewController.find() else {
                throw SkillError.unavailable("no window to present the picker from")
            }
            return top
        }.jc_pick(source)
        guard let image else { return nil }
        guard let jpeg = PhotoEncoding.jpeg(image, maxPixels: PhotoEncoding.defaultMaxPixels) else {
            throw SkillError.failed("could not encode the photo")
        }
        return CapturedImage(data: jpeg, mime: "image/jpeg")
    }
}

private extension UIViewController {
    /// Present the right picker and wait for one image (nil = cancelled).
    func jc_pick(_ source: PhotoSource) async throws -> UIImage? {
        switch source {
        case .library:
            return await withCheckedContinuation { cont in
                Task { @MainActor in
                    var config = PHPickerConfiguration(photoLibrary: .shared())
                    config.filter = .images
                    config.selectionLimit = 1
                    let picker = PHPickerViewController(configuration: config)
                    let delegate = PickerDelegate { cont.resume(returning: $0) }
                    picker.delegate = delegate
                    PickerDelegate.retain(delegate, for: picker)
                    self.present(picker, animated: true)
                }
            }
        case .camera:
            let available = await MainActor.run { UIImagePickerController.isSourceTypeAvailable(.camera) }
            guard available else { throw SkillError.unavailable("no camera on this device") }
            return await withCheckedContinuation { cont in
                Task { @MainActor in
                    let picker = UIImagePickerController()
                    picker.sourceType = .camera
                    let delegate = PickerDelegate { cont.resume(returning: $0) }
                    picker.delegate = delegate
                    PickerDelegate.retain(delegate, for: picker)
                    self.present(picker, animated: true)
                }
            }
        }
    }
}

/// One delegate for both pickers. The picker holds it via an associated
/// object so it lives exactly as long as the sheet.
private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate,
                                    UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var done: ((UIImage?) -> Void)?
    private static var key = 0

    init(_ done: @escaping (UIImage?) -> Void) { self.done = done }

    static func retain(_ delegate: PickerDelegate, for picker: UIViewController) {
        objc_setAssociatedObject(picker, &key, delegate, .OBJC_ASSOCIATION_RETAIN)
    }

    private func finish(_ picker: UIViewController, _ image: UIImage?) {
        let cb = done
        done = nil
        picker.dismiss(animated: true) { cb?(image) }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            finish(picker, nil)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async { self?.finish(picker, object as? UIImage) }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        finish(picker, (info[.editedImage] ?? info[.originalImage]) as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        finish(picker, nil)
    }
}

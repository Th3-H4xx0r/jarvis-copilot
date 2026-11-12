import AVFoundation
import UniformTypeIdentifiers

/// Streams a vault video into AVPlayer: AVFoundation asks for byte ranges, this fetches them from
/// `/items/<id>/content` with the vault token (a custom URL scheme is the only way to add a header),
/// and nothing goes through a disk cache.
final class VaultPlayerLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let item: VaultItem
    private let token: String
    private let api: VaultAPI
    private let queue = DispatchQueue(label: "vault.player")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var asset: AVURLAsset?
    /// Called on every range fetched, so a long video keeps the vault from idling shut.
    private let onActivity: @Sendable () -> Void

    /// The most AVFoundation gets per request in one go; it asks again for the rest.
    private let maxSpan = 4 * 1024 * 1024

    init(item: VaultItem, token: String, api: VaultAPI, onActivity: @escaping @Sendable () -> Void = {}) {
        self.item = item
        self.token = token
        self.api = api
        self.onActivity = onActivity
    }

    deinit { tasks.values.forEach { $0.cancel() } }

    /// Leaving the video: stop every fetch now rather than pulling the rest of a 2 GB file.
    func cancelAll() {
        queue.async { [weak self] in
            self?.tasks.values.forEach { $0.cancel() }
            self?.tasks.removeAll()
        }
    }

    func playerItem() -> AVPlayerItem {
        let url = URL(string: "jcvault://item/\(item.id).\(item.fileExtension)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        self.asset = asset
        return AVPlayerItem(asset: asset)
    }

    func resourceLoader(_ loader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType(mimeType: item.mime)?.identifier ?? UTType.mpeg4Movie.identifier
            info.contentLength = item.size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let key = ObjectIdentifier(request)
        let start = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let wanted = dataRequest.requestsAllDataToEndOfResource
            ? item.size - start
            : Int64(dataRequest.requestedLength) - (start - dataRequest.requestedOffset)
        let task = Task { [weak self, api, token, item, maxSpan, onActivity, queue] in
            var offset = start
            let end = min(item.size, start + max(0, wanted))
            defer { queue.async { self?.tasks.removeValue(forKey: key) } }
            do {
                while offset < end, !Task.isCancelled, !request.isCancelled {
                    onActivity()
                    let last = min(end, offset + Int64(maxSpan)) - 1
                    let (data, _) = try await api.send("GET", "/items/\(item.id)/content", token: token,
                                                       headers: ["Range": "bytes=\(offset)-\(last)"], timeout: 120)
                    if data.isEmpty { break }
                    dataRequest.respond(with: data)
                    offset += Int64(data.count)
                }
                if !Task.isCancelled, !request.isCancelled, !request.isFinished { request.finishLoading() }
            } catch {
                if !Task.isCancelled, !request.isCancelled, !request.isFinished { request.finishLoading(with: error) }
            }
        }
        tasks[key] = task
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
}

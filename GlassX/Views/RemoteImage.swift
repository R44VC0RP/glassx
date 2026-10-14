import ImageIO
import SwiftUI

/// Loads, downsamples and caches remote images off the main thread.
///
/// SwiftUI's `AsyncImage` keeps nothing in memory and decodes full-size images on the main
/// thread, so rows flash and stutter as the lazy feed recycles them. Here images are decoded
/// once at display size with ImageIO and kept in an in-memory cache keyed by URL and size, so a
/// row that scrolls back into view renders its images synchronously.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSString, CGImageBox>()
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<CGImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 256 << 20
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 1 << 30)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    private func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel) as NSString)?.image
    }

    func image(_ url: URL, maxPixel: Int) async -> CGImage? {
        let key = key(url, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit.image }

        lock.lock()
        if let task = inflight[key] {
            lock.unlock()
            return await task.value
        }
        let task = Task.detached(priority: .userInitiated) { [session] () -> CGImage? in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inflight[key] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inflight[key] = nil
        lock.unlock()
        if let image {
            cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Warms the cache for rows that are about to scroll into view.
    func prefetch(_ requests: [(URL, Int)]) {
        for (url, maxPixel) in requests where cached(url, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url, maxPixel: maxPixel) }
        }
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Maximum decoded pixel sizes for each kind of image.
enum ImageSize {
    static let avatar = 160
    static let largeAvatar = 400
    static let media = 1400
    static let thumbnail = 200
    static let banner = 1600
    static let full = 4096
}

struct RemoteImage: View {
    var url: URL?
    var maxPixel: Int = ImageSize.media
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    init(url: URL?, maxPixel: Int = ImageSize.media, contentMode: ContentMode = .fill) {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Color.xPlaceholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
            let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }
}

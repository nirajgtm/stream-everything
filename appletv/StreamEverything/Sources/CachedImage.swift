import SwiftUI
import ImageIO
import UIKit

/// Drop-in for AsyncImage with a real cache: a memory cache so a rail that scrolls
/// back into view paints at once, a disk cache so posters survive relaunches without a
/// download, and downsampling at decode time so a poster never costs more memory than
/// the pixels the TV shows. Without this every screen change re-downloaded every
/// poster and home came back blank.
struct CachedImage<Content: View>: View {
    let url: URL?
    var maxDim: CGFloat = 600
    @ViewBuilder let content: (CachedImagePhase) -> Content
    @State private var image: Image?

    init(url: URL?, maxDim: CGFloat = 600, @ViewBuilder content: @escaping (CachedImagePhase) -> Content) {
        self.url = url
        self.maxDim = maxDim
        self.content = content
        // Memory hits are applied synchronously so there is no empty frame at all.
        if let url, let cached = ImageStore.shared.cachedImage(for: url, maxDim: maxDim) {
            _image = State(initialValue: Image(uiImage: cached))
        }
    }

    var body: some View {
        // Color.clear gives the view a size while empty; a zero-size view never
        // "appears", so its task would never run and nothing would ever load.
        ZStack { Color.clear; content(CachedImagePhase(image: image)) }
            .task(id: url) {
                guard let url, image == nil else { return }
                if let loaded = await ImageStore.shared.image(for: url, maxDim: maxDim) {
                    image = Image(uiImage: loaded)
                }
            }
    }
}

struct CachedImagePhase {
    let image: Image?
}

/// Memory + disk cache of downsampled images, shared by SwiftUI and UIKit callers.
final class ImageStore {
    static let shared = ImageStore()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(_ url: URL, _ maxDim: CGFloat) -> NSString { "\(url.absoluteString)@\(Int(maxDim))" as NSString }

    private func file(for url: URL) -> URL {
        // A stable name per URL; the hash keeps names short and file-system safe.
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        return directory.appendingPathComponent(String(hasher.finalize(), radix: 36).replacingOccurrences(of: "-", with: "m"))
    }

    func cachedImage(for url: URL, maxDim: CGFloat) -> UIImage? {
        memory.object(forKey: key(url, maxDim))
    }

    func image(for url: URL, maxDim: CGFloat) async -> UIImage? {
        if let hit = cachedImage(for: url, maxDim: maxDim) { return hit }
        let id = key(url, maxDim) as String
        lock.lock()
        if let running = inFlight[id] {
            lock.unlock()
            return await running.value
        }
        let task = Task.detached(priority: .utility) { [self] () -> UIImage? in
            let path = file(for: url)
            var data = try? Data(contentsOf: path)
            if data == nil {
                do {
                    let (fetched, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        NSLog("UI image http %d url=%@", http.statusCode, url.absoluteString); return nil
                    }
                    data = fetched
                    try? fetched.write(to: path, options: .atomic)
                } catch {
                    NSLog("UI image error %@ url=%@", error.localizedDescription, url.absoluteString); return nil
                }
            }
            guard let data, let decoded = Self.downsample(data, maxDim: maxDim) else {
                NSLog("UI image failed url=%@ bytes=%d", url.absoluteString, data?.count ?? -1)
                return nil
            }
            memory.setObject(decoded, forKey: key(url, maxDim), cost: Int(decoded.size.width * decoded.size.height * 4))
            return decoded
        }
        inFlight[id] = task
        lock.unlock()
        let result = await task.value
        lock.lock(); inFlight[id] = nil; lock.unlock()
        return result
    }

    /// Decode straight to the display size through ImageIO; a full-size decode of a
    /// 2000px poster would cost 16 MB for a 220px card.
    static func downsample(_ data: Data, maxDim: CGFloat) -> UIImage? {
        // maxDim is in points; a 4K Apple TV draws 2 pixels per point (its `scale` still
        // reports 1, so ask for the native scale), otherwise everything comes out soft.
        let maxDim = maxDim * max(UIScreen.main.nativeScale, UIScreen.main.scale)
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDim)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Keep the disk cache bounded; oldest files go first. Call occasionally in the background.
    func trimDisk(maxBytes: Int = 400 * 1024 * 1024) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var total = 0
        let dated = items.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            total += values.fileSize ?? 0
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var index = 0
        while total > maxBytes, index < dated.count {
            try? FileManager.default.removeItem(at: dated[index].0)
            total -= dated[index].2
            index += 1
        }
    }
}

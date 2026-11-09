import AppKit
import CryptoKit

/// Loads thumbnails from the camera with a limit on parallel requests
/// (the GoPro's HTTP server easily hangs when overloaded),
/// plus an in-memory and an on-disk cache.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 3
    private let cacheDir: URL

    init() {
        memory.countLimit = 1500
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("GoProConnector/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    nonisolated static func cacheKey(_ item: MediaItem, kind: String) -> String {
        "\(kind)-\(item.historyKey)"
    }

    func image(for item: MediaItem, url: URL, client: GoProClient, kind: String = "thumb") async -> NSImage? {
        let key = Self.cacheKey(item, kind: kind)
        if let img = memory.object(forKey: key as NSString) { return img }

        let file = cacheDir.appendingPathComponent(Self.hash(key) + ".jpg")
        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }

        if let task = inFlight[key] { return await task.value.flatMap(NSImage.init(data:)) }

        let task = Task<Data?, Never> {
            await self.acquire()
            defer { self.release() }
            if Task.isCancelled { return nil }
            guard let data = try? await client.fetchData(url), NSImage(data: data) != nil else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[key] = task
        let img = await task.value.flatMap(NSImage.init(data:))
        inFlight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()   // the slot goes straight to the next waiter
        } else {
            running -= 1
        }
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

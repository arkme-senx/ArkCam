import AVFoundation
import ImageIO
import UIKit

private actor ThumbnailDecodeSlots {
    static let shared = ThumbnailDecodeSlots()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < 2 { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: i).1.resume(returning: false)
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume(returning: true) }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private struct Request {
        let task: Task<UIImage?, Never>
        var readers: Set<UUID>
    }
    private let cache = NSCache<NSString, UIImage>()
    private var requests: [String: Request] = [:]
    init() { cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 128 }

    func image(url: URL, kind: CaptureKind, maximumPixelSize: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        // URL resource values can themselves be cached after a file is replaced.
        let info = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(kind.rawValue)|\(maximumPixelSize)|\(modified)|\(info?[.size] as? NSNumber ?? 0)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let id = UUID()
        let task: Task<UIImage?, Never>
        if var current = requests[key] {
            current.readers.insert(id); requests[key] = current; task = current.task
        } else {
            task = Task.detached(priority: .utility) {
                guard await ThumbnailDecodeSlots.shared.acquire() else { return nil }
                let result = await Self.decode(url: url, kind: kind, maximumPixelSize: maximumPixelSize)
                await ThumbnailDecodeSlots.shared.release()
                return result
            }
            requests[key] = Request(task: task, readers: [id])
        }
        return await withTaskCancellationHandler {
            let result = await task.value
            release(key: key, reader: id)
            guard !Task.isCancelled else { return nil }
            if let result, let cg = result.cgImage {
                cache.setObject(result, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
            }
            return result
        } onCancel: { Task { await self.release(key: key, reader: id) } }
    }

    private func release(key: String, reader: UUID) {
        guard var current = requests[key], current.readers.remove(reader) != nil else { return }
        if current.readers.isEmpty { requests.removeValue(forKey: key); current.task.cancel() }
        else { requests[key] = current }
    }

    private nonisolated static func decode(url: URL, kind: CaptureKind, maximumPixelSize: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if kind == .photo {
            return autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                      ] as CFDictionary), !Task.isCancelled else { return nil }
                return UIImage(cgImage: image)
            }
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, let result = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
            return UIImage(cgImage: result.image)
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }
}

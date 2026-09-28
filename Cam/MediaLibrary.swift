import AVFoundation
import SwiftUI
import ImageIO

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []
    @Published var message: String?
    let disk: LibraryDisk
    let work = CaptureWorkScheduler()
    @Published private(set) var isLoading = false
    private var reloadTask: Task<Void, Never>?
    private var reloadRevision = 0
    private var changesDuringRead: [UUID: MemoryItem] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var recoveryRevision = 0
    private let readItems: @Sendable (LibraryDisk) throws -> [MemoryItem]

    init(disk: LibraryDisk = .standard,
         readItems: @escaping @Sendable (LibraryDisk) throws -> [MemoryItem] = { try $0.load() }) {
        self.disk = disk; self.readItems = readItems
    }

    /// Coalesce refreshes and keep directory traversal / decoding off the UI thread.
    func reload() {
        reloadRevision += 1
        guard reloadTask == nil else { return }
        isLoading = true
        reloadTask = Task { [weak self] in
            guard let self else { return }
            defer { reloadTask = nil; isLoading = false }
            while await work.waitUntilAvailable() {
                let revision = reloadRevision
                changesDuringRead.removeAll()
                let disk = disk, reader = readItems
                let result = await Task.detached(priority: .utility) { Result { try reader(disk) } }.value
                switch result {
                case .success(let loaded):
                    var merged = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    // A capture or edit can finish while the directory scan is in flight.
                    for (id, item) in changesDuringRead { merged[id] = item }
                    items = merged.values.sorted { $0.captureDate > $1.captureDate }
                case .failure(let error): message = "无法读取回忆：\(error.localizedDescription)"
                }
                changesDuringRead.removeAll()
                if revision == reloadRevision { break }
            }
        }
    }

    func reloadAndWait() async {
        if reloadTask == nil { reload() }
        await reloadTask?.value
    }

    func insert(_ item: MemoryItem) {
        if reloadTask != nil { changesDuringRead[item.id] = item }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else {
            let index = items.firstIndex { $0.captureDate < item.captureDate } ?? items.endIndex
            items.insert(item, at: index)
        }
    }

    func recoverInterruptedCaptures() async {
        recoveryRevision += 1
        if let recoveryTask { await recoveryTask.value; return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { recoveryTask = nil }
            var count = 0
            repeat {
                let revision = recoveryRevision
                await reloadAndWait()
                guard await work.waitUntilAvailable() else { return }
                let disk = disk
                let drafts = await Task.detached(priority: .utility) { disk.unfinishedDrafts() }.value
                for draft in drafts {
                    guard await work.waitUntilAvailable() else { return }
                    let recovered = await Task.detached(priority: .utility) { () -> MemoryItem? in
                        let rear = await Self.isReadable(draft.rearURL, kind: draft.item.kind)
                        let front = await Self.isReadable(draft.frontURL, kind: draft.item.kind)
                        let rearLive = await Self.isReadableMovie(draft.rearLiveURL)
                        let frontLive = await Self.isReadableMovie(draft.frontLiveURL)
                        return try? disk.finish(draft, rear: rear, front: front,
                            note: "上次拍摄中断，已保留能够恢复的素材。", rearLive: rearLive, frontLive: frontLive)
                    }.value
                    if let recovered { insert(recovered); count += 1 }
                }
                if revision == recoveryRevision { break }
            } while !Task.isCancelled
            if count > 0 { message = "已恢复 \(count) 条中断的拍摄，请在回忆中查看。" }
        }
        await recoveryTask?.value
    }

    nonisolated static func isReadable(_ url: URL, kind: CaptureKind) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if kind == .photo {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds.isFinite && duration.seconds > 0
    }

    nonisolated static func isReadableMovie(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds.isFinite && duration.seconds > 0
    }

    func updateLayout(for item: MemoryItem, layout: CameraLayout?) throws -> MemoryItem {
        var updated = item
        updated.layoutOverride = layout
        try disk.save(updated)
        insert(updated)
        return updated
    }

    func url(for item: MemoryItem, front: Bool) -> URL? {
        guard let name = front ? item.frontFile : item.rearFile else { return nil }
        return disk.folder(for: item.id).appendingPathComponent(name)
    }

    func renderURL(for item: MemoryItem, front: Bool, live: Bool = false) -> URL? {
        item.renderFile(front: front, live: live).map { disk.folder(for: item.id).appendingPathComponent($0) }
    }

    func liveURL(for item: MemoryItem, front: Bool) -> URL? {
        guard let name = front ? item.frontLiveFile : item.rearLiveFile else { return nil }
        return disk.folder(for: item.id).appendingPathComponent(name)
    }
}

enum ThumbnailLoader {
    static func image(url: URL, kind: CaptureKind, maximumPixelSize: Int = 800) async -> UIImage? {
        await ThumbnailCache.shared.image(url: url, kind: kind, maximumPixelSize: maximumPixelSize)
    }
}

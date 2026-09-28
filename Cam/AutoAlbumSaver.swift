import Foundation
import Photos
import UIKit

struct AlbumSaveReceipt: Codable, Equatable {
    enum Phase: String, Codable { case writing, saved, failed }
    var phase: Phase
    var assetIdentifier: String?
    var assetIdentifiers: [String]?
    var message: String?
    var savedAt: Date?
    var timing: AlbumSaveTiming?
}

struct AlbumSaveStore {
    let disk: LibraryDisk
    func url(_ id: UUID) -> URL { disk.folder(for: id).appendingPathComponent("album-save.json") }
    func receipt(_ id: UUID) throws -> AlbumSaveReceipt? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(AlbumSaveReceipt.self, from: Data(contentsOf: file))
    }
    func write(_ receipt: AlbumSaveReceipt, for id: UUID) throws {
        try JSONEncoder().encode(receipt).write(to: url(id), options: .atomic)
    }
    func needsSave(_ item: MemoryItem) -> Bool {
        guard item.albumSaveMode != nil else { return false }
        return (try? receipt(item.id))?.phase != .saved
    }
}

struct PreparedAlbumMedia {
    let file: URL
    let pairedMovie: URL?
    // Only disposable export files may be transferred to Photos. Never move
    // App-owned originals (including callers outside the automatic exporter).
    var canMoveFiles = false
}

enum AutomaticAlbumExport {
    typealias Writer = ([PreparedAlbumMedia], MemoryItem) async throws -> [String]

    static func save(_ captured: MemoryItem, disk: LibraryDisk,
                     queueSeconds: Double = 0,
                     progress: @escaping @Sendable (AlbumSaveStage) -> Void = { _ in },
                     writer: Writer = PhotosAlbumWriter.writeAll) async throws {
        guard let mode = captured.albumSaveMode else { return }
        let store = AlbumSaveStore(disk: disk)
        let existing = try store.receipt(captured.id)
        if existing?.phase == .saved { return }
        guard existing?.phase != .writing else {
            throw CamError.message("上次保存结果待确认，请先查看系统相册。")
        }
        guard captured.isComplete, let rearName = captured.renderFile(front: false), let frontName = captured.renderFile(front: true) else {
            throw CamError.message("原片未完整保存，请在回忆中检查；已有原片仍保留。")
        }
        // Auto-save always uses the captured composition, even if the user edits
        // the memory or preferences while a job is waiting.
        var item = captured
        item.layoutOverride = nil
        let snapshot = item
        let source = disk.folder(for: item.id)
        // In a locked extension, this stays inside the supplied session directory,
        // outside Memories so unfinished renders are never imported as originals.
        let folder = disk.root.deletingLastPathComponent().appendingPathComponent("AlbumExports")
            .appendingPathComponent(item.id.uuidString)
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        progress(.preparing)
        let prepareStart = ProcessInfo.processInfo.systemUptime
        let render = Task.detached(priority: .utility) { () async throws -> [PreparedAlbumMedia] in
            if mode == .separate && snapshot.capturedLayout.isDual {
                var media: [PreparedAlbumMedia] = []
                // Prepare both originals before submitting a single Photos transaction.
                // Keep this sequential to limit memory and concurrent video work.
                for camera in [MemoryExportMode.front, .rear] {
                    try Task.checkCancellation()
                    let cameraFolder = folder.appendingPathComponent(camera.rawValue)
                    try fm.createDirectory(at: cameraFolder, withIntermediateDirectories: true)
                    media.append(try await ManualAlbumExport.prepare(snapshot, mode: camera, disk: disk, folder: cameraFolder))
                }
                return media
            }
            // Single-camera captures keep their selected framing and create one asset.
            let renderMode = mode == .separate ? AlbumSaveMode.primary : mode
            let media = PreparedAlbumMedia(file: folder.appendingPathComponent(snapshot.kind == .photo ? "capture." + (snapshot.photoProfile?.processedFormat.fileExtension ?? "jpg") : "capture.mov"),
                                           pairedMovie: snapshot.isLivePhoto ? folder.appendingPathComponent("capture-live.mov") : nil)
            let rear = source.appendingPathComponent(rearName)
            let front = source.appendingPathComponent(frontName)
            if let paired = media.pairedMovie, let rearLive = snapshot.renderFile(front: false, live: true), let frontLive = snapshot.renderFile(front: true, live: true) {
                try await MediaExporter.makeLivePhoto(item: snapshot, rearPhotoURL: rear, frontPhotoURL: front,
                    rearMovieURL: source.appendingPathComponent(rearLive), frontMovieURL: source.appendingPathComponent(frontLive),
                    photoOutputURL: media.file, movieOutputURL: paired, mode: renderMode)
            } else if snapshot.kind == .photo {
                try MediaExporter.makePhoto(item: snapshot, rearURL: rear, frontURL: front, outputURL: media.file, mode: renderMode)
            } else {
                try await MediaExporter.makeVideo(item: snapshot, rearURL: rear, frontURL: front, outputURL: media.file, mode: renderMode)
            }
            return [media]
        }
        var media = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
        for index in media.indices { media[index].canMoveFiles = true }
        let prepareSeconds = ProcessInfo.processInfo.systemUptime - prepareStart
        try Task.checkCancellation()
        // Persist BEFORE the Photos transaction. If the process exits between the
        // external commit and our receipt, never blindly add a duplicate asset.
        try store.write(AlbumSaveReceipt(phase: .writing), for: item.id)
        progress(.writing)
        let writeStart = ProcessInfo.processInfo.systemUptime
        let identifiers: [String]
        do { identifiers = try await writer(media, snapshot) }
        catch {
            try store.write(AlbumSaveReceipt(phase: .failed, message: error.localizedDescription), for: item.id)
            throw error
        }
        // A receipt-write failure leaves .writing on disk, requiring reconciliation.
        try store.write(AlbumSaveReceipt(phase: .saved, assetIdentifier: identifiers.first, assetIdentifiers: identifiers,
            savedAt: Date(), timing: AlbumSaveTiming(queueSeconds: queueSeconds, prepareSeconds: prepareSeconds,
                writeSeconds: ProcessInfo.processInfo.systemUptime - writeStart)), for: item.id)
    }
}

enum PhotosAlbumWriter {
    private final class IdentifiersBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func append(_ identifier: String) { lock.lock(); value.append(identifier); lock.unlock() }
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func write(_ media: PreparedAlbumMedia, _ item: MemoryItem) async throws -> String {
        try await writeAll([media], item).first ?? ""
    }
    static func writeAll(_ media: [PreparedAlbumMedia], _ item: MemoryItem) async throws -> [String] {
        let identifiers = IdentifiersBox()
        // One transaction for both cameras: a rejected write must not leave half
        // a capture saved, and the durable receipt covers the entire batch.
        try await PHPhotoLibrary.shared().performChanges {
            for resource in media {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = item.createdAt
                request.location = item.captureMetadata?.location?.coreLocation
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = resource.canMoveFiles
                request.addResource(with: item.kind == .photo ? .photo : .video, fileURL: resource.file, options: options)
                if let paired = resource.pairedMovie { request.addResource(with: .pairedVideo, fileURL: paired, options: options) }
                identifiers.append(request.placeholderForCreatedAsset?.localIdentifier ?? "")
            }
        }
        return identifiers.get()
    }
}

@MainActor
final class AutoAlbumSaver: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var uncertainCount = 0
    @Published private(set) var uncertainItems: [MemoryItem] = []
    @Published private(set) var status = "新拍摄将自动保存到系统相册"
    @Published private(set) var issue: String?
    @Published private(set) var lastSavedID: UUID?
    @Published private(set) var itemStates: [UUID: AlbumItemSaveState] = [:]
    @Published private(set) var downloads: [UUID: [AlbumDownloadReceipt]] = [:]
    @Published private(set) var failures: [UUID: String] = [:]
    private var disk: LibraryDisk?
    private var items: [MemoryItem] = []
    private var canWork = false
    private var energy = CaptureEnergyState.current
    private var pressure: CameraPressureLevel = .normal
    private var cameraVisible = false
    private var capturing = false
    private var backgroundWorkAllowed = false
    private var receiptLoadTask: Task<Void, Never>?
    private var receiptGeneration = UUID()
    private var receiptVersions: [UUID: Int] = [:]
    private var receipts: [UUID: AlbumSaveReceipt] = [:]
    private var loadedReceipts = Set<UUID>()
    private var damaged = Set<UUID>()
    private var locked = false
    private var blocked = Set<UUID>()
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var activeHeavy: [UUID: Bool] = [:]
    private var stages: [UUID: AlbumSaveStage] = [:]
    private var manualStages: [UUID: AlbumSaveStage] = [:]
    private var manualWaiters: [CheckedContinuation<Void, Never>] = []
    private var queuedAt: [UUID: TimeInterval] = [:]
    #if !CAM_CAPTURE_EXTENSION
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    func state(for item: MemoryItem) -> AlbumItemSaveState { itemStates[item.id] ?? .unknown }
    func savedReceipt(for id: UUID) -> AlbumSaveReceipt? { receipts[id] }
    func isActive(_ id: UUID) -> Bool { workers[id] != nil }
    func isManualActive(_ id: UUID) -> Bool { manualStages[id] != nil }
    func canRetry(_ id: UUID) -> Bool { !damaged.contains(id) && workers[id] == nil && manualStages[id] == nil }
    func setManualStage(_ stage: AlbumSaveStage?, for id: UUID) {
        manualStages[id] = stage; refresh(id)
        if stage == nil { start() }
    }
    func waitForAutomaticSaves() async {
        guard !workers.isEmpty else { return }
        await withCheckedContinuation { manualWaiters.append($0) }
    }

    func update(items: [MemoryItem], disk: LibraryDisk, canWork: Bool, locked: Bool,
                energy: CaptureEnergyState = .current, pressure: CameraPressureLevel = .normal,
                cameraVisible: Bool = false, capturing: Bool = false, backgroundWorkAllowed: Bool = true) {
        if self.disk?.root != disk.root {
            // A locked-session store never shares receipt state with the full library.
            receipts.removeAll(); loadedReceipts.removeAll(); downloads.removeAll(); damaged.removeAll()
            receiptGeneration = UUID(); receiptVersions.removeAll()
        }
        self.energy = energy; self.pressure = pressure
        self.cameraVisible = cameraVisible; self.capturing = capturing
        self.backgroundWorkAllowed = backgroundWorkAllowed
        self.items = items; self.disk = disk; self.canWork = canWork; self.locked = locked
        refreshCounts()
        if canWork { start() }
    }

    private func invalidateReceipt(_ id: UUID) {
        loadedReceipts.remove(id)
        receiptVersions[id, default: 0] += 1
    }
    func refresh(_ id: UUID) { invalidateReceipt(id); refreshCounts() }

    func retry(itemID: UUID? = nil, includeUncertain: Bool = false) {
        guard let disk else { return }
        let candidates = items.filter {
            (itemID == nil || $0.id == itemID) && workers[$0.id] == nil &&
            (!loadedReceipts.contains($0.id) || needsSave($0) || damaged.contains($0.id))
        }
        if includeUncertain {
            do {
                let store = AlbumSaveStore(disk: disk)
                for item in candidates where item.albumSaveMode != nil {
                    if try store.receipt(item.id)?.phase == .writing {
                        try store.write(AlbumSaveReceipt(phase: .failed), for: item.id)
                    }
                }
            } catch { issue = "无法更新保存状态：\(error.localizedDescription)"; return }
        }
        for item in candidates {
            blocked.remove(item.id); failures.removeValue(forKey: item.id); invalidateReceipt(item.id)
        }
        issue = nil
        refreshCounts(); start()
    }

    private func waitingReason(for item: MemoryItem) -> String {
        if !canWork { return "等待返回 App" }
        if energy.thermal == .serious || energy.thermal == .critical { return "等待降温" }
        if capturing { return "等待拍摄结束" }
        if cameraVisible && pressure >= .serious { return "等待相机负载降低" }
        if Self.isHeavy(item) && cameraVisible {
            if energy.lowPower { return "低电量模式：进入回忆继续保存" }
            if energy.thermal != .nominal || pressure != .normal { return "等待降温，或进入回忆继续保存" }
        }
        return "正在排队"
    }

    private func refreshCounts() {
        guard let disk else { return }
        let ids = Set(items.map(\.id))
        loadedReceipts.formIntersection(ids)
        receipts = receipts.filter { ids.contains($0.key) }
        loadReceiptsIfNeeded(disk: disk)
        var next: [UUID: AlbumItemSaveState] = [:]
        for item in items {
            guard loadedReceipts.contains(item.id) else { next[item.id] = .unknown; continue }
            var value = AlbumItemSaveState.resolve(automatic: item.albumSaveMode != nil, receipt: receipts[item.id],
                damaged: damaged.contains(item.id), active: manualStages[item.id] ?? stages[item.id], waiting: waitingReason(for: item),
                downloads: downloads[item.id] ?? [])
            if blocked.contains(item.id), stages[item.id] == nil, manualStages[item.id] == nil,
               !damaged.contains(item.id), receipts[item.id]?.phase != .writing { value = .failed }
            next[item.id] = value
            if needsSave(item), queuedAt[item.id] == nil { queuedAt[item.id] = ProcessInfo.processInfo.systemUptime }
        }
        if itemStates != next { itemStates = next }
        pendingCount = items.filter(needsSave).count
        uncertainItems = items.filter { $0.albumSaveMode != nil && next[$0.id] == .uncertain }
        uncertainCount = uncertainItems.count
        isSaving = !workers.isEmpty
        status = items.contains(where: { !loadedReceipts.contains($0.id) }) ? "相册保存状态：正在读取…"
            : (pendingCount > 0 ? "\(pendingCount) 项待保存到系统相册" : "已保存到系统相册")
    }

    private struct ReceiptRead {
        let id: UUID
        let version: Int
        var receipt: AlbumSaveReceipt?
        var downloads: [AlbumDownloadReceipt] = []
        var error: String?
    }

    private func loadReceiptsIfNeeded(disk: LibraryDisk) {
        guard receiptLoadTask == nil, canWork, backgroundWorkAllowed,
              items.contains(where: { !loadedReceipts.contains($0.id) }) else { return }
        receiptLoadTask = Task { [weak self] in
            guard let self else { return }
            while canWork, backgroundWorkAllowed, !Task.isCancelled, self.disk?.root == disk.root {
                let batch = Array(items.filter { !self.loadedReceipts.contains($0.id) }.prefix(64))
                guard !batch.isEmpty else { break }
                let generation = receiptGeneration, versions = receiptVersions
                let values = await Task.detached(priority: .utility) {
                    let store = AlbumSaveStore(disk: disk)
                    return batch.map { item -> ReceiptRead in
                        var value = ReceiptRead(id: item.id, version: versions[item.id, default: 0])
                        do { value.receipt = try store.receipt(item.id); value.downloads = try store.downloads(item.id) }
                        catch { value.error = error.localizedDescription }
                        return value
                    }
                }.value
                guard generation == receiptGeneration else { break }
                let currentIDs = Set(items.map(\.id))
                var updatedDownloads = downloads
                for value in values where currentIDs.contains(value.id) && receiptVersions[value.id, default: 0] == value.version {
                    receipts[value.id] = value.receipt
                    updatedDownloads[value.id] = value.downloads
                    if let error = value.error {
                        damaged.insert(value.id); failures[value.id] = "无法更新保存状态：\(error)"
                    } else { damaged.remove(value.id) }
                    loadedReceipts.insert(value.id)
                }
                if downloads != updatedDownloads { downloads = updatedDownloads }
                refreshCounts(); start()
                await Task.yield()
            }
            receiptLoadTask = nil
            // A session root or an invalidated receipt may have changed during an await.
            if let current = self.disk { loadReceiptsIfNeeded(disk: current) }
        }
    }

    private func needsSave(_ item: MemoryItem) -> Bool {
        loadedReceipts.contains(item.id) && item.albumSaveMode != nil && receipts[item.id]?.phase != .saved
    }
    static func isHeavy(_ item: MemoryItem) -> Bool {
        item.kind == .video || item.isLivePhoto || (item.photoProfile?.megapixels ?? 12) >= 24
    }
    private func eligible(_ item: MemoryItem) -> Bool {
        needsSave(item) && !blocked.contains(item.id) && workers[item.id] == nil &&
            CaptureWorkPolicy.albumExport(energy: energy, pressure: pressure,
                cameraVisible: cameraVisible, capturing: capturing, heavy: Self.isHeavy(item))
    }

    // At most one video/Live export plus one still image. Extra concurrency is
    // permitted only at nominal temperature, with no active capture/low power.
    static func canSchedule(heavy: Bool, activeHeavy: [Bool], allowPhotoLane: Bool) -> Bool {
        if activeHeavy.isEmpty { return true }
        return allowPhotoLane && activeHeavy.count == 1 && activeHeavy[0] != heavy
    }

    private func start() {
        guard canWork, backgroundWorkAllowed, manualStages.isEmpty, let disk else { return }
        let allowPhotoLane = energy.thermal == .nominal && !energy.lowPower && pressure == .normal && !capturing &&
            PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        let ordered = items.sorted {
            if Self.isHeavy($0) != Self.isHeavy($1) { return !Self.isHeavy($0) }
            return $0.captureDate < $1.captureDate
        }
        for item in ordered where eligible(item) {
            let active = Array(activeHeavy.values)
            guard Self.canSchedule(heavy: Self.isHeavy(item), activeHeavy: active, allowPhotoLane: allowPhotoLane) else { continue }
            stages[item.id] = .preparing
            activeHeavy[item.id] = Self.isHeavy(item)
            workers[item.id] = Task { [weak self] in
                guard let self else { return }
                await self.process(item, disk: disk)
            }
        }
        refreshCounts()
        if !workers.isEmpty { beginBackgroundSave() }
    }

    private func process(_ item: MemoryItem, disk: LibraryDisk) async {
        let store = AlbumSaveStore(disk: disk)
        defer {
            stages.removeValue(forKey: item.id); workers.removeValue(forKey: item.id)
            activeHeavy.removeValue(forKey: item.id)
            invalidateReceipt(item.id); refreshCounts()
            if workers.isEmpty {
                endBackgroundSave()
                let waiters = manualWaiters; manualWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            if canWork { start() }
        }
        do {
            if try store.receipt(item.id)?.phase == .writing {
                blocked.insert(item.id)
                issue = "有一项保存结果待确认，请先查看系统相册，再决定是否重试。"
                return
            }
            var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if authorization == .notDetermined && !locked {
                authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            guard authorization == .authorized || authorization == .limited else {
                let message = locked ? "原片已保留。解锁打开 App 并允许添加照片后，将继续保存。"
                    : "原片已保留。请在系统设置允许添加照片，然后重试。"
                issue = message
                for pending in items where needsSave(pending) { blocked.insert(pending.id); failures[pending.id] = message }
                return
            }
            try Task.checkCancellation()
            guard canWork, backgroundWorkAllowed, CaptureWorkPolicy.albumExport(energy: energy, pressure: pressure,
                cameraVisible: cameraVisible, capturing: capturing, heavy: Self.isHeavy(item)) else { return }
            let waited = max(0, ProcessInfo.processInfo.systemUptime - (queuedAt[item.id] ?? ProcessInfo.processInfo.systemUptime))
            try await AutomaticAlbumExport.save(item, disk: disk, queueSeconds: waited, progress: { [weak self] stage in
                Task { @MainActor in
                    guard let self, self.workers[item.id] != nil else { return }
                    self.stages[item.id] = stage; self.refreshCounts()
                }
            })
            lastSavedID = item.id
            queuedAt.removeValue(forKey: item.id)
            if blocked.isEmpty { issue = nil }
        } catch {
            if !Task.isCancelled {
                blocked.insert(item.id); failures[item.id] = error.localizedDescription
                issue = "自动保存尚未完成：\(error.localizedDescription) 原片仍在回忆中。"
            }
        }
    }

    private func beginBackgroundSave() {
        #if !CAM_CAPTURE_EXTENSION
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Cam to Photos") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.workers.values.forEach { $0.cancel() }; self.endBackgroundSave()
            }
        }
        #endif
    }
    private func endBackgroundSave() {
        #if !CAM_CAPTURE_EXTENSION
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
        #endif
    }
}

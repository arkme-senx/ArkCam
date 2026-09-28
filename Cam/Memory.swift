import Foundation
import CoreGraphics

enum CaptureKind: String, Codable, CaseIterable {
    case photo, video
    var title: String { self == .photo ? "照片" : "视频" }
    var aspectRatio: CGFloat { self == .photo ? 3 / 4 : 9 / 16 }
    var fileExtension: String { self == .photo ? "jpg" : "mov" }
}

// UI mode and media type are separate so existing memories remain compatible.
enum CameraCaptureMode: String, CaseIterable {
    case singleVideo, dualVideo, dualPhoto, singlePhoto
    var kind: CaptureKind { self == .singleVideo || self == .dualVideo ? .video : .photo }
    var isDual: Bool { self == .dualPhoto || self == .dualVideo }
    var title: String { switch self { case .singlePhoto: "单拍"; case .singleVideo: "单录"; case .dualPhoto: "双拍"; case .dualVideo: "双录" } }
    var accessibilityTitle: String { (isDual ? "双摄像头" : "单摄像头") + kind.title }
    static func restored(_ raw: String) -> Self {
        if raw == "video" { return .dualVideo }
        return Self(rawValue: raw) ?? .dualPhoto
    }
}

enum CaptureAspect: String, Codable, CaseIterable, Identifiable {
    case standard = "4:3", wide = "16:9", square = "1:1"
    var id: String { rawValue }
    var ratio: CGFloat { switch self { case .standard: 3 / 4; case .wide: 9 / 16; case .square: 1 } }
}

struct CameraLayout: Codable, Equatable {
    var frontIsPrimary = false
    // nil means the original two-camera format, including incomplete old pairs.
    var singleCamera: Bool?
    var isDual: Bool { singleCamera != true }
    func includes(front: Bool) -> Bool { isDual || front == frontIsPrimary }
    func complete(rear: Bool, front: Bool) -> Bool {
        (!includes(front: false) || rear) && (!includes(front: true) || front)
    }
    // Optional fields preserve the geometry of memories saved before build 20.
    var aspect: CaptureAspect?
    var insetAspectRatio: Double?
    var orientation: CameraOrientation?
    func aspectRatio(for kind: CaptureKind) -> CGFloat {
        let ratio = aspect?.ratio ?? kind.aspectRatio
        return orientation?.isLandscape == true ? 1 / ratio : ratio
    }
    // Position in the available travel area, independent of preview/export resolution.
    // Missing in older memories: retain their 2.5% inset until the user moves the PiP.
    var pipEdgeToEdge: Bool?
    var x: Double = 1
    var y: Double = 1

    func moved(by translation: CGSize, in size: CGSize) -> CameraLayout {
        let pip = pipRect(in: size)
        var next = self
        next.pipEdgeToEdge = true
        let newPip = next.pipRect(in: size)
        // Translate the visible origin, not legacy normalized coordinates, so an
        // old composition does not jump when its first drag enables edge placement.
        next.x = min(1, max(0, (pip.minX + translation.width) / max(1, size.width - newPip.width)))
        next.y = min(1, max(0, (pip.minY + translation.height) / max(1, size.height - newPip.height)))
        return next
    }

    func pipRect(in size: CGSize) -> CGRect {
        let margin = pipEdgeToEdge == true ? 0 : size.width * 0.025
        var width = max(0, size.width * 0.30)
        var height: CGFloat = insetAspectRatio.map { width / CGFloat(max(0.1, $0)) } ?? size.height * 0.30
        if pipEdgeToEdge == true, height > size.height {
            width *= max(0, size.height) / height
            height = max(0, size.height)
        }
        return CGRect(x: margin + CGFloat(max(0, min(1, x))) * max(0, size.width - width - 2 * margin),
                      y: margin + CGFloat(max(0, min(1, y))) * max(0, size.height - height - 2 * margin),
                      width: width, height: height)
    }
}

struct LayoutMoment: Codable, Equatable {
    var seconds: Double
    var layout: CameraLayout
}

struct RecordingBufferStatistics: Codable, Equatable {
    var rearFramesDiscarded: Int
    var frontFramesDiscarded: Int
    var audioSamplesDiscarded: Int
    // Sum of each queue's peak, an upper bound, not a simultaneous measurement.
    var peakQueuedBytesUpperBound: Int
}

enum RecordingStopReason: String, Codable {
    case requested, capturePaused, startCancelled, startTimeout, writerFailure, systemInterruption, runtimeError
}

struct RecordingDiagnostics: Codable, Equatable {
    var reason: RecordingStopReason
    var trigger: String?
    var stoppedAt: Date
    var build: String
    var pressureLevel: Int
    var thermalState: Int
    var interruptionReason: Int?
    var errorDomain: String?
    var errorCode: Int?
    var buffer: RecordingBufferStatistics
    var finalizationIssue: String?
}

struct MemoryItem: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var kind: CaptureKind
    var rearFile: String?
    var frontFile: String?
    var duration: Double?
    var capturedLayout: CameraLayout
    var layoutMoments: [LayoutMoment] = []
    var layoutOverride: CameraLayout?
    var captureNote: String?
    var recordingDiagnostics: RecordingDiagnostics?
    var captureMetadata: CaptureMetadata?
    var rearLiveFile: String?
    var frontLiveFile: String?
    var livePhotoDuration: Double?
    var livePhotoDisplayTime: Double?
    // nil identifies older/manual fixtures: never backfill the whole library.
    var albumSaveMode: AlbumSaveMode?
    var videoProfile: VideoRecordingProfile?
    var photoProfile: PhotoCaptureProfile?
    var rearRawFile: String?
    var frontRawFile: String?
    // ISO8601 legacy dates omit fractions; retain capture order for rapid taps.
    var captureTimestamp: Double?
    var captureDate: Date { captureTimestamp.map(Date.init(timeIntervalSince1970:)) ?? createdAt }

    var aspectRatio: CGFloat { capturedLayout.aspectRatio(for: kind) }

    var isComplete: Bool { capturedLayout.complete(rear: rearFile != nil, front: frontFile != nil) }
    var isLivePhoto: Bool { kind == .photo && capturedLayout.complete(rear: rearLiveFile != nil, front: frontLiveFile != nil) }

    // Rendering slots may share the selected single original; storage never duplicates it.
    // Missing halves of dual captures remain nil and cannot be mistaken for single captures.
    func renderFile(front: Bool, live: Bool = false) -> String? {
        let selectedFront = capturedLayout.isDual ? front : capturedLayout.frontIsPrimary
        return live ? (selectedFront ? frontLiveFile : rearLiveFile) : (selectedFront ? frontFile : rearFile)
    }

    func layout(at seconds: Double = 0) -> CameraLayout {
        if let layoutOverride { return layoutOverride }
        return layoutMoments.last(where: { $0.seconds <= seconds })?.layout ?? capturedLayout
    }
}

struct CaptureDraft {
    let item: MemoryItem
    let folder: URL
    var rearURL: URL { folder.appendingPathComponent("rear.\(fileExtension)") }
    var frontURL: URL { folder.appendingPathComponent("front.\(fileExtension)") }
    private var fileExtension: String { item.kind == .photo ? (item.photoProfile?.processedFormat.fileExtension ?? "jpg") : "mov" }
    func rawURL(front: Bool) -> URL { folder.appendingPathComponent(front ? "front.dng" : "rear.dng") }
    var rearLiveURL: URL { folder.appendingPathComponent("rear-live.mov") }
    var frontLiveURL: URL { folder.appendingPathComponent("front-live.mov") }
}

enum CamError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// In-process recovery/import must not adopt files still being written by the camera.
enum CaptureDraftActivity {
    private static let lock = NSLock()
    private static var active = Set<UUID>()
    static func begin(_ id: UUID) { lock.lock(); defer { lock.unlock() }; active.insert(id) }
    static func end(_ id: UUID) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
    static func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active.contains(id) }
}

struct LibraryDisk {
    let root: URL

    static var standard: LibraryDisk {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryDisk(root: base.appendingPathComponent("Cam/Memories", isDirectory: true))
    }

    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func createDraft(kind: CaptureKind, layout: CameraLayout, metadata: CaptureMetadata? = nil,
                     albumSaveMode: AlbumSaveMode? = nil, videoProfile: VideoRecordingProfile? = nil, photoProfile: PhotoCaptureProfile? = nil, inFlight: Bool = false) throws -> CaptureDraft {
        let draft = reserveDraft(kind: kind, layout: layout, metadata: metadata,
            albumSaveMode: albumSaveMode, videoProfile: videoProfile, photoProfile: photoProfile, inFlight: inFlight)
        do { try writeDraft(draft); return draft }
        catch { if inFlight { CaptureDraftActivity.end(draft.item.id) }; throw error }
    }

    // Reserve identity immediately; the video worker performs all filesystem I/O.
    func reserveDraft(kind: CaptureKind, layout: CameraLayout, metadata: CaptureMetadata? = nil,
                      albumSaveMode: AlbumSaveMode? = nil, videoProfile: VideoRecordingProfile? = nil, photoProfile: PhotoCaptureProfile? = nil,
                      inFlight: Bool = false) -> CaptureDraft {
        let date = Date()
        let item = MemoryItem(id: UUID(), createdAt: date, kind: kind, capturedLayout: layout,
            captureMetadata: metadata, albumSaveMode: albumSaveMode, videoProfile: videoProfile, photoProfile: photoProfile,
            captureTimestamp: date.timeIntervalSince1970)
        if inFlight { CaptureDraftActivity.begin(item.id) }
        return CaptureDraft(item: item, folder: folder(for: item.id))
    }

    func writeDraft(_ draft: CaptureDraft) throws {
        // Attempt the actual write, also inside a locked-capture session directory.
        try FileManager.default.createDirectory(at: draft.folder, withIntermediateDirectories: true)
        try encoder.encode(draft.item).write(to: draft.folder.appendingPathComponent("draft.json"), options: .atomic)
    }

    func finish(_ draft: CaptureDraft, rear: Bool, front: Bool, duration: Double? = nil,
                moments: [LayoutMoment] = [], note: String? = nil,
                rearLive: Bool = false, frontLive: Bool = false,
                livePhotoDuration: Double? = nil, livePhotoDisplayTime: Double? = nil) throws -> MemoryItem {
        // Keep the stop reason even when neither writer could finalize. This
        // small sidecar travels with the originals and locked-session import.
        if let diagnostics = draft.item.recordingDiagnostics {
            try? encoder.encode(diagnostics).write(to: draft.folder.appendingPathComponent("recording-stop.json"), options: .atomic)
        }
        guard rear || front || rearLive || frontLive else {
            // Leave the draft and any partial files available for recovery.
            throw CamError.message(note ?? "这次拍摄未能保存，请重新拍摄。")
        }
        var item = draft.item
        item.rearFile = rear ? draft.rearURL.lastPathComponent : nil
        item.frontFile = front ? draft.frontURL.lastPathComponent : nil
        item.rearRawFile = FileManager.default.fileExists(atPath: draft.rawURL(front: false).path) ? "rear.dng" : nil
        item.frontRawFile = FileManager.default.fileExists(atPath: draft.rawURL(front: true).path) ? "front.dng" : nil
        item.duration = duration
        item.layoutMoments = moments
        item.captureNote = note
        item.rearLiveFile = rearLive ? draft.rearLiveURL.lastPathComponent : nil
        item.frontLiveFile = frontLive ? draft.frontLiveURL.lastPathComponent : nil
        item.livePhotoDuration = item.isLivePhoto ? livePhotoDuration : nil
        item.livePhotoDisplayTime = item.isLivePhoto ? livePhotoDisplayTime : nil
        try save(item)
        return item
    }

    func save(_ item: MemoryItem) throws {
        let directory = folder(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(item).write(to: directory.appendingPathComponent("memory.json"), options: .atomic)
        // Only superseded bookkeeping is removed; source images and movies are retained.
        let draft = directory.appendingPathComponent("draft.json")
        if FileManager.default.fileExists(atPath: draft.path) { try? FileManager.default.removeItem(at: draft) }
    }

    func load() throws -> [MemoryItem] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return folders.compactMap { folder in
            let metadata = folder.appendingPathComponent("memory.json")
            guard let data = try? Data(contentsOf: metadata),
                  var item = try? decoder.decode(MemoryItem.self, from: data) else { return nil }
            if let name = item.rearFile, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                item.rearFile = nil
                item.captureNote = "后摄原片缺失，已保留其余素材。"
            }
            if let name = item.frontFile, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                item.frontFile = nil
                item.captureNote = "前摄原片缺失，已保留其余素材。"
            }
            if let name = item.rearLiveFile, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                item.rearLiveFile = nil
                item.livePhotoDuration = nil
                item.livePhotoDisplayTime = nil
                item.captureNote = "后摄 Live 原片缺失，静态照片仍已保留。"
            }
            if let name = item.frontLiveFile, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                item.frontLiveFile = nil
                item.livePhotoDuration = nil
                item.livePhotoDisplayTime = nil
                item.captureNote = "前摄 Live 原片缺失，静态照片仍已保留。"
            }
            return item
        }.sorted { $0.captureDate > $1.captureDate }
    }

    func unfinishedDrafts() -> [CaptureDraft] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("draft.json")),
                  let item = try? decoder.decode(MemoryItem.self, from: data),
                  !CaptureDraftActivity.contains(item.id) else { return nil }
            return CaptureDraft(item: item, folder: folder)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

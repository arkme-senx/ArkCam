import CryptoKit
import Foundation
import LockedCameraCapture
import UIKit

enum LockedCaptureImport {
    // Copy, verify, atomically publish, then write a receipt. Never modify a
    // session's originals; only the manager may invalidate a completed session.
    static func receive(session: URL, into disk: LibraryDisk) throws -> Int {
        let fm = FileManager.default
        let source = session.appendingPathComponent("Memories", isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return 0 }
        let directories = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let receipts = disk.root.appendingPathComponent(".locked-receipts", isDirectory: true)
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)
        var imported = 0
        for folder in directories {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let id = UUID(uuidString: folder.lastPathComponent) else {
                throw CamError.message("锁屏素材目录无法识别，已保留原文件。")
            }
            let files = try fingerprints(in: folder)
            let metadata = files["memory.json"] != nil ? "memory.json" : "draft.json"
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let item = try decoder.decode(MemoryItem.self, from: Data(contentsOf: folder.appendingPathComponent(metadata)))
            guard item.id == id else { throw CamError.message("锁屏素材标识不一致，已保留原文件。") }
            let receipt = receipts.appendingPathComponent(id.uuidString + ".json")
            let target = disk.folder(for: id)
            if fm.fileExists(atPath: target.path) {
                let existing = try fingerprints(in: target)
                let received = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                // Once received, layout/metadata may be edited by the app. The
                // original media must still match before acknowledging a retry.
                let mediaMatch = files.filter { !$0.key.hasSuffix(".json") }.allSatisfy { existing[$0.key] == $0.value }
                guard existing == files || (received == files && mediaMatch) else {
                    throw CamError.message("锁屏素材与已有回忆冲突，已保留两份文件。")
                }
            } else {
                let staging = receipts.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
                defer { try? fm.removeItem(at: staging) }
                try fm.copyItem(at: folder, to: staging)
                guard try fingerprints(in: staging) == files else {
                    throw CamError.message("锁屏素材校验未通过，原片仍保留在拍摄目录。")
                }
                try fm.moveItem(at: staging, to: target)
                imported += 1
            }
            try JSONEncoder().encode(files).write(to: receipt, options: .atomic)
        }
        return imported
    }

    private static func fingerprints(in folder: URL) throws -> [String: String] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var result: [String: String] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CamError.message("锁屏素材包含无法接收的文件，已保留原文件。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            result[url.lastPathComponent] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

@available(iOS 18.0, *)
@MainActor
enum LockedCaptureReceiver {
    enum Signal: Sendable {
        case reconcile
        case sessions([URL])
    }

    static func observe(library: MediaLibrary) async {
        let manager = LockedCameraCaptureManager.shared
        let (signals, continuation) = AsyncStream<Signal>.makeStream()
        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in continuation.yield(.reconcile) }
        let updates = Task { @MainActor in
            let changes = manager.sessionContentUpdates
            // Recheck after constructing the listener too, so a session added
            // during startup cannot fall between the snapshot and subscription.
            continuation.yield(.reconcile)
            for await update in changes {
                guard !Task.isCancelled else { return }
                switch update {
                case .initial(let existing): continuation.yield(.sessions(existing))
                case .added(let added): continuation.yield(.sessions([added]))
                case .removed: continue
                @unknown default: continue
                }
            }
        }
        defer {
            updates.cancel()
            NotificationCenter.default.removeObserver(foreground)
            continuation.finish()
        }
        await consume(signals, snapshot: { manager.sessionContentURLs }, receive: { url in
            guard await library.work.waitUntilAvailable() else { throw CancellationError() }
            let disk = library.disk
            _ = try await Task.detached(priority: .utility) {
                try LockedCaptureImport.receive(session: url, into: disk)
            }.value
            try Task.checkCancellation()
            await library.recoverInterruptedCaptures()
            try Task.checkCancellation()
            try await manager.invalidateSessionContent(at: url)
        }, onFailure: { error in
            library.message = "锁屏拍摄的素材尚未完全接收，原片已保留。\(error.localizedDescription)"
        })
    }

    // Some devices expose pending URLs without delivering an initial stream
    // event. Read the snapshot independently, then serialize all later signals.
    // Only successful acknowledgements are deduplicated; failures may retry on
    // the next foreground reconciliation without losing the system's originals.
    static func consume(_ signals: AsyncStream<Signal>,
                        snapshot: @MainActor () -> [URL],
                        receive: @MainActor (URL) async throws -> Void,
                        onFailure: @MainActor (Error) -> Void) async {
        var completed = Set<URL>()
        func receiveAll(_ urls: [URL]) async {
            for url in urls {
                guard !Task.isCancelled else { return }
                let key = url.standardizedFileURL
                guard !completed.contains(key) else { continue }
                do {
                    try await receive(url)
                    completed.insert(key)
                } catch {
                    guard !Task.isCancelled else { return }
                    onFailure(error)
                }
            }
        }
        await receiveAll(snapshot())
        for await signal in signals {
            guard !Task.isCancelled else { return }
            switch signal {
            case .reconcile: await receiveAll(snapshot())
            case .sessions(let urls): await receiveAll(urls)
            }
        }
    }
}

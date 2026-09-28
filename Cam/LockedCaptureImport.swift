import CryptoKit
import Foundation
import LockedCameraCapture

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
    static func observe(library: MediaLibrary) async {
        for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
            guard !Task.isCancelled else { return }
            let urls: [URL]
            switch update {
            case .initial(let existing): urls = existing
            case .added(let added): urls = [added]
            case .removed: continue
            @unknown default: continue
            }
            for url in urls {
                guard await library.work.waitUntilAvailable() else { return }
                do {
                    let disk = library.disk
                    _ = try await Task.detached(priority: .utility) {
                        try LockedCaptureImport.receive(session: url, into: disk)
                    }.value
                    await library.recoverInterruptedCaptures()
                    try await LockedCameraCaptureManager.shared.invalidateSessionContent(at: url)
                } catch {
                    library.message = "锁屏拍摄的素材尚未完全接收，原片已保留。\(error.localizedDescription)"
                }
            }
        }
    }
}

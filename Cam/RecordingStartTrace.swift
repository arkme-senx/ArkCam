import Foundation
import QuartzCore

/// Per-take timestamps, separate from the UI's acceptance or timer state.
final class RecordingStartTrace: @unchecked Sendable {
    private let began = CACurrentMediaTime()
    private let lock = NSLock()
    private var phases: [String: Double] = [:]
    func mark(_ phase: String) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        if phases[phase] == nil { phases[phase] = CACurrentMediaTime() - began }
        #endif
    }
    func save(id: UUID) {
        #if DEBUG
        lock.lock(); let values = phases; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CamDiagnostics/RecordingStart")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: ["id": id.uuidString, "phases": values], options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        }
        #endif
    }
}

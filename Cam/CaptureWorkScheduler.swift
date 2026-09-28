import Foundation
import Combine

/// Admission control for optional work, not a lock around capture or durable writes.
@MainActor
final class CaptureWorkScheduler: ObservableObject {
    enum Phase: Equatable { case suspended, starting, capturing, preview, browsing }
    @Published private(set) var allowsBackgroundWork = false
    private(set) var phase: Phase = .starting
    private let quietInterval: TimeInterval
    private var quietUntil: TimeInterval = 0
    private var settleTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(quietInterval: TimeInterval = 0.3) { self.quietInterval = quietInterval }

    func setPhase(_ value: Phase) {
        guard value != phase else { return }
        phase = value
        settleTask?.cancel(); settleTask = nil
        setAllowed(false)
        if value == .browsing { setAllowed(true) }
        else if value == .preview { userInteracted() }
    }

    func userInteracted() {
        guard phase == .preview else { return }
        quietUntil = ProcessInfo.processInfo.systemUptime + quietInterval
        setAllowed(false)
        guard settleTask == nil else { return }
        settleTask = Task { [weak self] in
            while let self, !Task.isCancelled, phase == .preview {
                let remaining = quietUntil - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 {
                    settleTask = nil; setAllowed(true); return
                }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
        }
    }

    func waitUntilAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        if allowsBackgroundWork { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }

    private func setAllowed(_ value: Bool) {
        if allowsBackgroundWork != value { allowsBackgroundWork = value }
        if value {
            let ready = waiters.values; waiters.removeAll()
            ready.forEach { $0.resume(returning: true) }
        }
    }

    deinit {
        settleTask?.cancel()
        waiters.values.forEach { $0.resume(returning: false) }
    }
}

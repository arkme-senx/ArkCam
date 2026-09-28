import AVFoundation

/// Offline encoders wake us when an input is ready, instead of polling every 2 ms.
/// Each lane returns false immediately after its last append, allowing the muxer
/// to finish one track even while another encoder is applying backpressure.
enum MediaWriterDrain {
    struct Lane {
        let input: AVAssetWriterInput
        let appendNext: () throws -> Bool
    }

    static func run(writer: AVAssetWriter, lanes: [Lane], end: CMTime) throws {
        let state = State(writer: writer, lanes: lanes, end: end)
        state.start()
        guard state.done.wait(timeout: .now() + 12) == .success else {
            state.cancel()
            throw CamError.message("Live Photo 动态原片保存失败。")
        }
        if let error = state.error { throw error }
    }

    private final class State: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let queue = DispatchQueue(label: "cam.media-drain", qos: .utility)
        private let writer: AVAssetWriter
        private let lanes: [Lane]
        private let end: CMTime
        private var finished: Set<Int> = []
        private var finishing = false
        private var completed = false
        // Written before the semaphore signal, read only after a successful wait.
        private(set) var error: Error?
        init(writer: AVAssetWriter, lanes: [Lane], end: CMTime) {
            self.writer = writer; self.lanes = lanes; self.end = end
        }
        func start() {
            for index in lanes.indices {
                lanes[index].input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drain(index) }
            }
        }
        func cancel() {
            queue.async { [self] in
                guard !completed else { return }
                writer.cancelWriting()
                complete(CamError.message("Live Photo 动态原片保存失败。"))
            }
        }
        private func drain(_ index: Int) {
            guard !completed, !finishing, !finished.contains(index) else { return }
            let lane = lanes[index]
            do {
                while lane.input.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw writer.error ?? CamError.message("Live Photo 媒体写入失败。")
                    }
                    if try !lane.appendNext() {
                        lane.input.markAsFinished(); finished.insert(index); break
                    }
                }
                if finished.count == lanes.count {
                    finishing = true
                    writer.endSession(atSourceTime: end)
                    writer.finishWriting { [weak self] in
                        guard let self else { return }
                        self.queue.async { [self] in
                            self.complete(self.writer.status == .completed ? nil : self.writer.error ?? CamError.message("Live Photo 动态原片保存失败。"))
                        }
                    }
                }
            } catch { writer.cancelWriting(); complete(error) }
        }
        private func complete(_ error: Error?) {
            guard !completed else { return }
            completed = true; self.error = error; done.signal()
        }
    }
}

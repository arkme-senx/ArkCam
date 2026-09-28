import AVFoundation
import SwiftUI

struct VideoLayoutFrames {
    let rear: UIImage
    let front: UIImage
}

@MainActor
final class MemoryPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isWaiting = false
    @Published private(set) var isReady = false
    @Published private(set) var hasFirstFrame = false
    @Published private(set) var isLoading = false
    @Published var error: String?
    private var recipe: VideoRecipe?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var loadingTimeout: Task<Void, Never>?
    private var layoutRefreshTask: Task<Void, Never>?
    private var needsLayoutRefresh = false
    private var generation = 0
    private var loadedID: UUID?
    private var itemIsReady = false
    private var firstSeekFinished = false
    private var playRequested = false
    private var rearURL: URL?
    private var frontURL: URL?
    private var sourceStart = CMTime.zero

    init() {
        player.allowsExternalPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.loadedID != nil, time.seconds.isFinite else { return }
                self.position = max(0, min(self.duration, time.seconds))
            }
        }
        playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                let state = player.timeControlStatus
                self?.isPlaying = state == .playing
                self?.isWaiting = state == .waitingToPlayAtSpecifiedRate
                if state == .paused { self?.refreshPausedPreview() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.playRequested = false
                self.player.pause()
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                let reason = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.fail(reason?.localizedDescription ?? "视频播放失败，请重新打开这条回忆。")
            }
        }
    }

    deinit {
        loadingTimeout?.cancel()
        layoutRefreshTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    /// Invalidates unfinished loads/seeks before moving to a different memory.
    func unload() {
        generation += 1
        loadedID = nil
        loadingTimeout?.cancel(); loadingTimeout = nil
        layoutRefreshTask?.cancel(); layoutRefreshTask = nil
        itemObserver = nil
        playRequested = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        recipe = nil; rearURL = nil; frontURL = nil
        needsLayoutRefresh = false
        sourceStart = .zero
        position = 0; duration = 0
        itemIsReady = false; firstSeekFinished = false
        hasFirstFrame = false; isReady = false; isLoading = false
        isPlaying = false; isWaiting = false; error = nil
    }

    func load(_ item: MemoryItem, rear: URL, front: URL) async {
        guard loadedID != item.id else { return }
        loadedID = item.id
        generation += 1
        let currentGeneration = generation
        layoutRefreshTask?.cancel()
        layoutRefreshTask = nil
        needsLayoutRefresh = false
        player.pause()
        playRequested = false
        itemObserver = nil
        recipe = nil
        rearURL = rear
        frontURL = front
        sourceStart = .zero
        position = 0
        duration = max(0, item.duration ?? 0)
        hasFirstFrame = false
        itemIsReady = false
        firstSeekFinished = false
        isReady = false
        isLoading = true
        error = nil
        loadingTimeout?.cancel()
        loadingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.generation == currentGeneration, !self.isReady else { return }
            self.fail("视频准备时间过长，请返回后重新打开。原片仍保留在 App 中。")
        }
        do {
            // setCategory can synchronously wait on the audio daemon. Keep
            // that IPC off the main actor so opening a memory cannot freeze
            // the SwiftUI run loop while the player is being prepared.
            try await Self.preparePlaybackAudioSession()
            var original = item
            original.layoutOverride = nil
            let recipe = try await MediaExporter.videoRecipe(item: original, rearURL: rear, frontURL: front)
            let loadedDuration = try await recipe.composition.load(.duration).seconds
            guard generation == currentGeneration, !Task.isCancelled, error == nil else { return }
            self.recipe = recipe
            sourceStart = recipe.sourceStart
            duration = loadedDuration
            (recipe.videoComposition.instructions.first as? PairCompositionInstruction)?.setPreviewLayout(item.layoutOverride)
            let playerItem = AVPlayerItem(asset: recipe.composition)
            playerItem.videoComposition = recipe.videoComposition
            playerItem.seekingWaitsForVideoCompositionRendering = true
            itemObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] playerItem, _ in
                let status = playerItem.status
                let reason = playerItem.error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if status == .failed { self.fail(reason ?? "视频读取失败。") }
                    else {
                        self.itemIsReady = status == .readyToPlay
                        self.updateReadiness()
                    }
                }
            }
            player.replaceCurrentItem(with: playerItem)
            // Metadata availability does not mean AVPlayerItem can play yet.
            while playerItem.status == .unknown {
                try await Task.sleep(for: .milliseconds(30))
                guard generation == currentGeneration, error == nil else { return }
            }
            guard playerItem.status == .readyToPlay else {
                throw playerItem.error ?? CamError.message("视频尚未准备好。")
            }
            guard generation == currentGeneration, !Task.isCancelled, error == nil else { return }
            itemIsReady = true
            // Prime the first composited frame before enabling the play button.
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if !finished, self.error == nil { self.fail("首帧读取失败，请重新打开这条回忆。") }
                    else { self.firstSeekFinished = finished; self.updateReadiness() }
                }
            }
            updateReadiness()
        } catch is CancellationError {
            if generation == currentGeneration { isLoading = false; loadingTimeout?.cancel() }
        } catch {
            if generation == currentGeneration { fail(error.localizedDescription) }
        }
    }

    func displayReadinessChanged(_ ready: Bool) {
        guard player.currentItem != nil, error == nil else { return }
        hasFirstFrame = ready
        updateReadiness()
    }

    private func updateReadiness() {
        isReady = itemIsReady && firstSeekFinished && hasFirstFrame && error == nil
        if isReady { isLoading = false; loadingTimeout?.cancel() }
    }

    private func fail(_ reason: String) {
        player.pause()
        playRequested = false
        isReady = false
        isLoading = false
        loadingTimeout?.cancel()
        error = reason
    }

    func updateLayout(_ layout: CameraLayout?, interactive: Bool = false) {
        guard let recipe else { return }
        (recipe.videoComposition.instructions.first as? PairCompositionInstruction)?.setPreviewLayout(layout)
        needsLayoutRefresh = true
        // During playback the compositor reads the latest layout for each frame.
        // Replacing its configuration for every touch sample interrupts that work.
        guard player.rate == 0 else { return }
        if !interactive { finishLayoutInteraction(); return }
        guard layoutRefreshTask == nil else { return }
        layoutRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            guard let self else { return }
            self.layoutRefreshTask = nil
            self.refreshPausedPreview()
        }
    }

    func finishLayoutInteraction() {
        layoutRefreshTask?.cancel()
        layoutRefreshTask = nil
        refreshPausedPreview()
    }

    func layoutFramesAtCurrentTime() async -> VideoLayoutFrames? {
        guard let rearURL, let frontURL else { return nil }
        let sourceTime = sourceStart + player.currentTime()
        do {
            async let rear = Self.frame(url: rearURL, at: sourceTime)
            async let front = Self.frame(url: frontURL, at: sourceTime)
            return try await VideoLayoutFrames(rear: rear, front: front)
        } catch {
            return nil
        }
    }

    func commitLayoutInteraction(_ layout: CameraLayout?, completion: @escaping () -> Void) {
        guard let recipe, let item = player.currentItem else { completion(); return }
        layoutRefreshTask?.cancel()
        layoutRefreshTask = nil
        needsLayoutRefresh = false
        (recipe.videoComposition.instructions.first as? PairCompositionInstruction)?.setPreviewLayout(layout)
        // Replace the composition once, after the finger lifts. Seeking to the
        // current frame gives the player a deterministic redraw completion.
        item.videoComposition = recipe.videoComposition.mutableCopy() as? AVMutableVideoComposition
        let current = player.currentTime()
        player.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in if finished { completion() } else { completion() } }
        }
    }

    private func refreshPausedPreview() {
        guard needsLayoutRefresh, player.rate == 0, error == nil,
              let recipe, let item = player.currentItem else { return }
        needsLayoutRefresh = false
        // A paused item needs an explicit redraw. Coalesce touch events and always
        // flush the final layout when the finger lifts or playback pauses.
        item.videoComposition = recipe.videoComposition.mutableCopy() as? AVMutableVideoComposition
    }

    func toggle() {
        guard isReady else { return }
        if playRequested || player.timeControlStatus != .paused { pause() }
        else { resume() }
    }

    func resume() {
        guard isReady else { return }
        playRequested = true
        let currentGeneration = generation
        Task { @MainActor [weak self] in
            do {
                try await Self.activatePlaybackAudioSession()
                guard let self, self.generation == currentGeneration,
                      self.playRequested, self.isReady else { return }
                self.player.play()
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.playRequested = false
                self.fail("无法播放声音：\(error.localizedDescription)")
            }
        }
    }

    func playFromBeginning() {
        guard isReady else { return }
        playRequested = true
        let currentGeneration = generation
        Task { @MainActor [weak self] in
            do {
                try await Self.activatePlaybackAudioSession()
                guard let self, self.generation == currentGeneration,
                      self.playRequested, self.isReady else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    guard finished else { return }
                    Task { @MainActor in
                        guard let self, self.generation == currentGeneration, self.playRequested else { return }
                        self.player.play()
                    }
                }
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.playRequested = false
                self.fail("无法播放声音：\(error.localizedDescription)")
            }
        }
    }

    func seek(_ seconds: Double) {
        guard isReady, seconds.isFinite else { return }
        position = min(duration, max(0, seconds))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() { playRequested = false; player.pause() }

    private static func frame(url: URL, at time: CMTime) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1920)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let result = try await generator.image(at: time)
        return UIImage(cgImage: result.image)
    }

    private nonisolated static let playbackAudioQueue = DispatchQueue(
        label: "cam.playback-audio", qos: .userInitiated)

    private nonisolated static func preparePlaybackAudioSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playbackAudioQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    // Avoid repeating the synchronous daemon round-trip when
                    // another memory already configured the same route.
                    if session.category != .playback || session.mode != .moviePlayback {
                        try session.setCategory(.playback, mode: .moviePlayback)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func activatePlaybackAudioSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playbackAudioQueue.async {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var onReadyForDisplay: (Bool) -> Void

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ uiView: Host, context: Context) {
        uiView.onReadyForDisplay = onReadyForDisplay
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            uiView.observeReadiness()
        }
        uiView.playerLayer.videoGravity = .resizeAspect
    }

    final class Host: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onReadyForDisplay: ((Bool) -> Void)?
        private var observer: NSKeyValueObservation?

        func observeReadiness() {
            observer = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in self?.onReadyForDisplay?(ready) }
            }
        }
    }
}

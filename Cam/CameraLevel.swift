import SwiftUI
import CoreMotion

struct CameraGravity: Equatable {
    var x: Double
    var y: Double
    var z: Double

    var normalized: Self? {
        let length = sqrt(x * x + y * y + z * z)
        guard length.isFinite, length > 0.5, length < 1.5 else { return nil }
        return Self(x: x / length, y: y / length, z: z / length)
    }
}

struct CameraLevelReading: Equatable {
    enum Mode: String { case hidden, horizon, flat }
    var mode: Mode = .hidden
    var referenceDegrees = 0.0
    var tiltDegrees = 0.0
    var offset = CGPoint.zero
    var aligned = false
    static let hidden = Self()
    var displayValue: Self {
        var value = self
        value.tiltDegrees = (tiltDegrees * 10).rounded() / 10
        value.offset.x = (offset.x * 3).rounded() / 3
        value.offset.y = (offset.y * 3).rounded() / 3
        return value
    }
}

/// Gravity is expressed in the device frame: +x right, +y toward its top,
/// +z out of the screen. UIKit's downward y axis reverses the displayed slope.
struct CameraLevelEstimator {
    private(set) var reading = CameraLevelReading.hidden
    private var filtered: CameraGravity?
    private var lastTimestamp: TimeInterval?
    private var flatActive = false
    private var horizonActive = false

    mutating func reset() { self = Self() }

    mutating func update(_ input: CameraGravity, timestamp: TimeInterval) -> CameraLevelReading {
        guard let gravity = input.normalized, timestamp.isFinite else {
            reset(); return reading
        }
        if let lastTimestamp, timestamp <= lastTimestamp { return reading }
        let delta = lastTimestamp.map { timestamp - $0 } ?? 1
        lastTimestamp = timestamp
        // Discard stale state after interruptions. A short, time-based filter
        // removes sensor noise without depending on an exact callback rate.
        if let previous = filtered, delta < 0.5 {
            let alpha = 1 - exp(-delta / 0.045)
            filtered = CameraGravity(x: previous.x + alpha * (gravity.x - previous.x),
                                     y: previous.y + alpha * (gravity.y - previous.y),
                                     z: previous.z + alpha * (gravity.z - previous.z)).normalized
        } else { filtered = gravity; flatActive = false; horizonActive = false; reading = .hidden }
        guard let value = filtered else { reset(); return reading }
        let flatTilt = acos(min(1, abs(value.z))) * 180 / .pi
        // Hysteresis prevents a flat/horizon flicker when tilting through the boundary.
        flatActive = flatTilt <= (flatActive ? 28 : 20)
        if flatActive {
            horizonActive = false
            let aligned = flatTilt <= (reading.mode == .flat && reading.aligned ? 1.5 : 0.7)
            reading = CameraLevelReading(mode: .flat,
                offset: aligned ? .zero : CGPoint(x: value.x * 96, y: -value.y * 96), aligned: aligned)
            return reading
        }

        let angle = atan2(-value.x, -value.y) * 180 / .pi
        let reference = (angle / 90).rounded() * 90
        let tilt = angle - reference
        horizonActive = abs(tilt) <= (horizonActive ? 17 : 12)
        guard horizonActive else { reading = .hidden; return reading }
        let aligned = abs(tilt) <= (reading.mode == .horizon && reading.aligned ? 1.5 : 0.7)
        // A line has no arrow: 0° and 180° are identical. Avoid a full rotation
        // of the graphic when the device crosses the ±180° Euler boundary.
        let axis = abs(reference.truncatingRemainder(dividingBy: 180))
        reading = CameraLevelReading(mode: .horizon, referenceDegrees: axis,
                                     tiltDegrees: aligned ? 0 : tilt, aligned: aligned)
        return reading
    }
}

/// Estimation stays on the serial motion queue. One mailbox delivery can be
/// pending on the main actor, so a busy animation never replays stale samples.
final class CameraLevelSampleProcessor: @unchecked Sendable {
    struct Sample { let reading: CameraLevelReading; let uptime: TimeInterval }
    private var estimator = CameraLevelEstimator()
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var lastPublished = CameraLevelReading.hidden
    private var lastDelivery = -Double.infinity
    private let lock = NSLock()
    private var latest: Sample?
    private var deliveryPending = false

    func consume(_ gravity: CameraGravity, timestamp: TimeInterval, uptime: TimeInterval) -> Bool {
        if !timestamp.isFinite || gravity.normalized == nil {
            firstTimestamp = nil; lastTimestamp = nil; estimator.reset()
        } else {
            if let lastTimestamp, timestamp <= lastTimestamp { return false }
            if lastTimestamp == nil || timestamp - lastTimestamp! > 0.5 {
                firstTimestamp = timestamp; estimator.reset()
            }
            lastTimestamp = timestamp
        }
        let value = estimator.update(gravity, timestamp: timestamp).displayValue
        let ready = firstTimestamp.map { timestamp - $0 >= 0.1 } ?? false
        let reading: CameraLevelReading = ready ? value : .hidden
        guard reading != lastPublished || uptime - lastDelivery >= 0.2 else { return false }
        lastPublished = reading; lastDelivery = uptime
        lock.lock(); defer { lock.unlock() }
        latest = Sample(reading: reading, uptime: uptime)
        if deliveryPending { return false }
        deliveryPending = true
        return true
    }

    func takeLatest() -> Sample? {
        lock.lock(); defer { lock.unlock() }
        let result = latest; latest = nil; deliveryPending = false
        return result
    }
}

@MainActor
final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var reading = CameraLevelReading.hidden
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "cam.level.motion"; queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var active = false
    private var generation = 0
    private var lastSampleAt: TimeInterval?
    private var watchdog: Task<Void, Never>?
    #if DEBUG
    private var samples = 0
    private var diagnostics: [[String: Any]] = []
    #endif

    func setActive(_ enabled: Bool) {
        guard enabled != active else { return }
        generation += 1
        let token = generation
        active = enabled
        lastSampleAt = nil
        reading = .hidden
        if !enabled {
            motion.stopDeviceMotionUpdates()
            watchdog?.cancel(); watchdog = nil
            record(event: "stop")
            return
        }
        #if DEBUG && targetEnvironment(simulator)
        if let fixture = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--level-fixture=") }) {
            let name = String(fixture.dropFirst("--level-fixture=".count))
            let value: CameraGravity
            switch name {
            case "flat": value = CameraGravity(x: 0.08, y: -0.12, z: -sqrt(1 - 0.08 * 0.08 - 0.12 * 0.12))
            case "flat-aligned": value = CameraGravity(x: 0, y: 0, z: -1)
            case "aligned": value = CameraGravity(x: 0, y: -1, z: 0)
            case "hidden": value = CameraGravity(x: 0.707, y: -0.707, z: 0)
            default: value = CameraGravity(x: 0.10, y: -sqrt(0.99), z: 0)
            }
            var estimator = CameraLevelEstimator()
            reading = estimator.update(value, timestamp: 1)
            return
        }
        #endif
        guard motion.isDeviceMotionAvailable else { active = false; record(event: "unavailable"); return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.showsDeviceMovementDisplay = false
        // Gravity does not need compass heading or a camera image analysis pass.
        let processor = CameraLevelSampleProcessor()
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] data, error in
            guard let data, error == nil else {
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    setActive(false)
                }
                return
            }
            let gravity = CameraGravity(x: data.gravity.x, y: data.gravity.y, z: data.gravity.z)
            guard processor.consume(gravity, timestamp: data.timestamp,
                uptime: ProcessInfo.processInfo.systemUptime) else { return }
            Task { @MainActor [weak self] in
                guard let self, active, generation == token else { return }
                guard let sample = processor.takeLatest() else { return }
                lastSampleAt = sample.uptime
                if sample.reading != reading { reading = sample.reading }
                #if DEBUG
                samples += 1
                if samples % 30 == 0 { record(event: "sample") }
                #endif
            }
        }
        record(event: "start")
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, active, generation == token else { return }
                if let lastSampleAt, ProcessInfo.processInfo.systemUptime - lastSampleAt > 0.5 {
                    reading = .hidden
                }
            }
        }
    }

    deinit { motion.stopDeviceMotionUpdates(); watchdog?.cancel() }

    private func record(event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--audit-level") else { return }
        diagnostics.append(["event": event, "uptime": ProcessInfo.processInfo.systemUptime,
            "samples": samples, "active": active, "motionActive": motion.isDeviceMotionActive,
            "mode": reading.mode.rawValue, "aligned": reading.aligned,
            "referenceDegrees": reading.referenceDegrees, "tiltDegrees": reading.tiltDegrees,
            "offsetX": reading.offset.x, "offsetY": reading.offset.y])
        diagnostics = Array(diagnostics.suffix(60))
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("level.json"), options: .atomic)
        #endif
    }
}

/// This small subtree owns the observable sensor, keeping 30 Hz updates out of
/// CaptureScreen, the capture session, the PiP and the rest of the controls.
struct CameraLevelOverlay: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let active: Bool
    let scale: CGFloat
    var orientation = CameraOrientation.portrait
    @StateObject private var monitor = CameraLevelMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = interfaceLanguage
        ZStack {
            if active, monitor.reading.mode != .hidden {
                CameraLevelGraphic(reading: monitor.reading, scale: scale)
                    .rotationEffect(.degrees(orientation.overlayRotation))
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text(monitor.reading.mode == .flat ? "俯仰拍摄水平仪" : "水平仪"))
                    .accessibilityValue(L10n.text(monitor.reading.aligned ? "已对齐" : "未对齐"))
                    .accessibilityIdentifier("cameraLevel-" + monitor.reading.mode.rawValue)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: monitor.reading.mode)
        .allowsHitTesting(false)
        .task { monitor.setActive(active) }
        .onChange(of: active) { _, enabled in monitor.setActive(enabled) }
        .onDisappear { monitor.setActive(false) }
    }
}

struct CameraLevelGraphic: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let reading: CameraLevelReading
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = interfaceLanguage
        Group {
            if reading.mode == .horizon {
                ZStack {
                    HStack(spacing: 130 * scale) {
                        line(width: 22); line(width: 22)
                    }
                    line(width: reading.aligned ? 130 : 120)
                        .rotationEffect(.degrees(reading.tiltDegrees))
                }
                .foregroundStyle(reading.aligned ? Color.yellow : Color.white.opacity(0.88))
                .rotationEffect(.degrees(reading.referenceDegrees))
            } else if reading.mode == .flat {
                ZStack {
                    if !reading.aligned { cross.foregroundStyle(.white.opacity(0.85)) }
                    cross.foregroundStyle(.yellow)
                        .offset(x: reading.offset.x * scale, y: reading.offset.y * scale)
                }
            }
        }
        .frame(width: 174 * scale, height: 174 * scale)
        .shadow(color: .black.opacity(0.28), radius: 0.5 * scale)
        // Sensor smoothing removes noise; short interpolation fills the interval
        // between samples without a spring that overshoots the true level.
        .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30), value: reading)
    }

    private func line(width: CGFloat) -> some View {
        Rectangle().frame(width: width * scale, height: 0.85 * scale)
    }
    private var cross: some View {
        ZStack {
            Rectangle().frame(width: 32 * scale, height: 0.85 * scale)
            Rectangle().frame(width: 0.85 * scale, height: 32 * scale)
        }
    }
}

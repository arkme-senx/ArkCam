import Foundation
import SwiftUI

struct CaptureEnergyState: Equatable {
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPower = false
    static var current: Self {
        Self(thermal: ProcessInfo.processInfo.thermalState,
             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    var pressure: CameraPressureLevel {
        switch thermal {
        case .critical: return .critical
        case .serious: return .serious
        case .fair: return .fair
        default: return lowPower ? .fair : .normal
        }
    }
}

enum CaptureWorkPolicy {
    static func frameRate(requested: Int32, pressure: CameraPressureLevel,
                          videoMode: Bool, recording: Bool) -> Int32 {
        // Keep the always-on preview below the recording cadence in both photo
        // and video modes. Recording still uses its requested rate until the
        // device reports serious pressure, where the thermal plan takes over.
        let plan = CameraLoadPolicy.plan(level: pressure, causes: [])
        let rate = recording ? requested : min(plan.frameRate, requested)
        return pressure >= .serious ? min(rate, plan.frameRate) : rate
    }

    static func liveBuffer(requested: Bool, running: Bool, videoMode: Bool,
                           hasVideoFormat: Bool, recording: Bool) -> Bool {
        requested && running && !videoMode && !hasVideoFormat && !recording
    }

    static func albumExport(energy: CaptureEnergyState, pressure: CameraPressureLevel,
                            cameraVisible: Bool, capturing: Bool, heavy: Bool) -> Bool {
        guard !capturing, energy.thermal != .serious, energy.thermal != .critical else { return false }
        guard cameraVisible else { return true }
        guard pressure < .serious else { return false }
        return !heavy || (energy.thermal == .nominal && !energy.lowPower && pressure == .normal)
    }
}

@MainActor
final class CaptureEnergyMonitor: ObservableObject {
    @Published private(set) var state = CaptureEnergyState.current
    private var tokens: [NSObjectProtocol] = []
    init() {
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state = .current }
            })
        }
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

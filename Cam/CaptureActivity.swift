import Foundation

/// A photo and a finishing movie can overlap; neither completion owns the other.
struct CaptureActivity {
    let recording: Bool
    let savingVideo: Bool
    let takingPhoto: Bool
    var pendingPhotos: Int = 0
    var capacityReached: Bool = false
    var isBusy: Bool { takingPhoto || capacityReached }
    var canEndBackgroundSave: Bool { !recording && !savingVideo && !takingPhoto && pendingPhotos == 0 }
    var canUseShutter: Bool { recording || !isBusy }
}

enum PhotoShutterSoundPolicy {
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        CameraDefaults.bool("cameraShutterSound", in: defaults)
    }

    static func suppress(isPrimary: Bool, supported: Bool, soundEnabled: Bool = true) -> Bool {
        supported && (!soundEnabled || !isPrimary)
    }
}

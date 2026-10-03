import Foundation

/// Factory preferences shared by the app, locked camera and capture intent.
/// Registration provides fallbacks; it never replaces a user's saved choice.
enum CameraDefaults {
    static let versionKey = "cameraDefaultsVersion"
    static let livePhotoEnabled = false
    static let captureMode = "dualPhoto"
    static let videoResolution = "1080p"
    static let videoFPS = 30
    static let videoProfile = "\(videoResolution)-\(videoFPS)"
    static let photoFormat = "jpeg"
    static let photoMegapixels = 12

    static let booleans: [String: Bool] = [
        "livePhotoEnabled": livePhotoEnabled,
        "cameraGrid": true, "cameraLevel": true, "cameraStabilization": true,
        "cameraEnhancedStabilization": false, "cameraLocation": true,
        "cameraRemember": true, "cameraMirrorFront": true,
        "cameraMainLens28": true, "cameraMainLens35": true, "cameraShutterSound": true
    ]
    static let strings: [String: String] = [
        "cameraLanguage": "system", "cameraPhotoAspect": "4:3", "cameraVideoAspect": "16:9",
        "cameraFlash": "off", "cameraMode": captureMode, "cameraAlbumSaveMode": "dual",
        "cameraSingleVideoProfile": videoProfile, "cameraDualVideoProfile": videoProfile,
        "cameraDefaultMainLens": "native", "cameraPhotoFormat": photoFormat,
        "cameraPhotoMP": String(photoMegapixels), "cameraPhotoTimer": "0"
    ]

    static func bool(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: key) else { return booleans[key]! }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on": return true
            case "false", "no", "n", "0", "off": return false
            default: break
            }
        }
        return booleans[key]!
    }
    static func string(_ key: String, in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? strings[key]!
    }

    static func prepare(_ defaults: UserDefaults = .standard,
                        domainName: String? = Bundle.main.bundleIdentifier,
                        hasExistingMedia: Bool = false) {
        // Inspect persisted values, never registered fallbacks or launch arguments.
        // Earlier versions had Live on without necessarily persisting its value.
        let saved = domainName.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        if saved[versionKey] == nil {
            let hasLegacyPreferences = booleans.keys.contains { saved[$0] != nil } ||
                strings.keys.contains { saved[$0] != nil }
            if saved["livePhotoEnabled"] == nil && (hasLegacyPreferences || hasExistingMedia) {
                defaults.set(true, forKey: "livePhotoEnabled")
            }
            defaults.set(1, forKey: versionKey)
        }
        var values: [String: Any] = booleans.mapValues { $0 as Any }
        strings.forEach { values[$0.key] = $0.value }
        defaults.register(defaults: values)
    }
}

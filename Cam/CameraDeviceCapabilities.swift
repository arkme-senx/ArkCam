import AVFoundation

/// Hardware discovery, independent of model names and screen dimensions.
/// A simulator fixture is an explicit test scenario, never a hardware claim.
enum CameraDeviceCapabilities {
    static var supportsDualCapture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") { return true }
        if ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture") {
            return !ProcessInfo.processInfo.arguments.contains("--single-camera-only")
        }
        #endif
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
            .builtInTrueDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video, position: .unspecified)
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        return discovery.supportedMultiCamDeviceSets.contains { set in
            guard let front, set.contains(front) else { return false }
            return set.contains { device in
                device.position == .back && device.formats.contains { format in
                    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return format.isMultiCamSupported && size.width <= 1920 && size.height <= 1440 &&
                        CameraFormatGeometry.supportsLiveBuffer(CMFormatDescriptionGetMediaSubType(format.formatDescription)) &&
                        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                }
            }
        }
    }

    static func modes(dual: Bool) -> [CameraCaptureMode] {
        dual ? CameraCaptureMode.allCases : [.singleVideo, .singlePhoto]
    }
    static func resolved(_ requested: CameraCaptureMode, dual: Bool) -> CameraCaptureMode {
        guard requested.isDual && !dual else { return requested }
        return requested.kind == .photo ? .singlePhoto : .singleVideo
    }
}

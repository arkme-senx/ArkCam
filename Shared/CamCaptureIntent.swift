import AppIntents
import Foundation

struct CamCaptureContext: Codable, Sendable {
    var livePhotoEnabled: Bool = CameraDefaults.livePhotoEnabled
    var options: [String: String]?
}

@available(iOS 18.0, *)
struct CamCaptureIntent: CameraCaptureIntent {
    typealias AppContext = CamCaptureContext
    static let title: LocalizedStringResource = "双面拍摄"
    static let description = IntentDescription("同时记录眼前的画面和镜头后面的你。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if CAM_MAIN_APP
        CameraLaunchRoute.shared.destination = .camera
        #endif
        return .result()
    }
}

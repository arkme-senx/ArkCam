import LockedCameraCapture
import ExtensionKit
import SwiftUI

@main
struct CamCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in LockedCaptureView(session: session) }
    }
}

struct LockedCaptureView: View {
    let session: LockedCameraCaptureSession
    @StateObject private var library: MediaLibrary
    @StateObject private var camera: DualCamera
    @StateObject private var location: CaptureLocationService

    init(session: LockedCameraCaptureSession) {
        self.session = session
        CameraDefaults.prepare()
        let disk = LibraryDisk(root: session.sessionContentURL.appendingPathComponent("Memories", isDirectory: true))
        let metadata = CaptureMetadataProvider()
        _library = StateObject(wrappedValue: MediaLibrary(disk: disk))
        _camera = StateObject(wrappedValue: DualCamera(disk: disk, metadataProvider: metadata))
        _location = StateObject(wrappedValue: CaptureLocationService(provider: metadata))
    }

    var body: some View {
        CaptureScreen(camera: camera, library: library, locationService: location)
            .modifier(LocalizedInterface())
            .preferredColorScheme(.dark)
            .tint(.white)
            .environment(\.captureAccess, CaptureAccess(openApplication: { destination in
                let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
                activity.userInfo = ["destination": destination]
                try await session.openApplication(for: activity)
            }))
            .task {
                library.reload()
            }
    }
}

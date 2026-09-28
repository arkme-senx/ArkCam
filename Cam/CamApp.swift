import SwiftUI
import LockedCameraCapture

@main
struct CamApp: App {
    @StateObject private var library: MediaLibrary
    @StateObject private var camera: DualCamera
    @StateObject private var locationService: CaptureLocationService

    init() {
        var hasExistingMedia = FileManager.default.fileExists(atPath: LibraryDisk.standard.root.path)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture"),
           ProcessInfo.processInfo.arguments.contains("--ui-reset-factory-preferences") {
            // Test-only preference reset; never removes media or runs on a phone.
            for key in Array(CameraDefaults.booleans.keys) + Array(CameraDefaults.strings.keys) + [CameraDefaults.versionKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            hasExistingMedia = false
        }
        #endif
        CameraDefaults.prepare(hasExistingMedia: hasExistingMedia)
        #if DEBUG
        if let language = ProcessInfo.processInfo.environment["ARKCAM_TEST_LANGUAGE"] {
            UserDefaults.standard.set(language, forKey: "cameraLanguage")
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture") {
            UserDefaults.standard.set("0", forKey: "cameraPhotoTimer")
            UserDefaults.standard.set("jpeg", forKey: "cameraPhotoFormat")
            UserDefaults.standard.set("12", forKey: "cameraPhotoMP")
        }
        #endif
        let disk: LibraryDisk
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture") {
            disk = LibraryDisk(root: FileManager.default.temporaryDirectory.appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--single-gallery-fixture") ? "CamSingleGalleryV26" : "CamQuickTakeUIFixture"))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--album-status-fixture") ? "CamAlbumStatusTestFixturesV52" : ProcessInfo.processInfo.arguments.contains("--gallery-fixtures") ? "CamGalleryTestFixturesV21" : ProcessInfo.processInfo.arguments.contains("--ui-locked") ? "CamLockedTestFixturesV16" : "CamTestFixturesResumeV15")
            disk = LibraryDisk(root: root)
        } else { disk = .standard }
        #else
        disk = .standard
        #endif
        let metadataProvider = CaptureMetadataProvider()
        _library = StateObject(wrappedValue: MediaLibrary(disk: disk))
        _camera = StateObject(wrappedValue: DualCamera(disk: disk, metadataProvider: metadataProvider))
        _locationService = StateObject(wrappedValue: CaptureLocationService(provider: metadataProvider))
    }

    private var captureAccess: CaptureAccess {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixtures"),
           ProcessInfo.processInfo.arguments.contains("--ui-locked") {
            return CaptureAccess(openApplication: { _ in throw CamError.message("模拟身份验证取消") })
        }
        #endif
        return CaptureAccess()
    }

    @ViewBuilder
    private var captureRoot: some View {
        if #available(iOS 18.0, *) {
            CaptureScreen(camera: camera, library: library, locationService: locationService)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") || ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture") { return }
                    #endif
                    await LockedCaptureReceiver.observe(library: library)
                }
                .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { activity in
                    CameraLaunchRoute.shared.destination = activity.userInfo?["destination"] as? String == "library" ? .library : .camera
                }

        } else {
            CaptureScreen(camera: camera, library: library, locationService: locationService)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if NSClassFromString("XCTestCase") != nil {
                // Hosted unit tests exercise media/Photos independently of a
                // running capture UI. UI tests launch without XCTest in the app.
                Color.black
            } else if ProcessInfo.processInfo.arguments.contains("--ui-about-preview") {
                AboutPreview()
            } else {
                applicationContent
            }
            #else
            applicationContent
            #endif
        }
    }

    private var applicationContent: some View {
            captureRoot
                .modifier(LocalizedInterface())
                .environment(\.captureAccess, captureAccess)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--single-gallery-fixture") {
                        try? await DebugFixtures.seedSingle(disk: library.disk)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ui-fixtures") {
                        try? await DebugFixtures.seed(disk: library.disk)
                    }
                    #endif
                    await library.recoverInterruptedCaptures()
                }
    }
}

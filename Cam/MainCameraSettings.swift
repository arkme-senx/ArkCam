import SwiftUI
import AVFoundation

struct CameraLensDescription: Identifiable {
    let id: String
    let title: String
    let front: Bool
    let type: AVCaptureDevice.DeviceType
    static func detected() -> [Self] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified).devices.map { device in
                Self(id: device.uniqueID,
                    title: device.position == .front ? "前置相机" : device.deviceType == .builtInUltraWideCamera ? "超广角" : device.deviceType == .builtInTelephotoCamera ? "长焦" : "主摄",
                    front: device.position == .front, type: device.deviceType)
            }.sorted { $0.front == $1.front ? $0.title < $1.title : !$0.front }
    }
}

enum MainCameraPreference {
    static func factors(main: Double?, maximum: Double, defaults: UserDefaults = .standard) -> [Double] {
        guard let main, main > 0, main < 28 else { return [1] }
        return [1] + [28.0, 35].filter {
            CameraDefaults.bool("cameraMainLens\(Int($0))", in: defaults) && $0 / main <= maximum
        }.map { $0 / main }
    }
    static func initial(main: Double?, maximum: Double, defaults: UserDefaults = .standard) -> Double {
        guard let main, let mm = Double(defaults.string(forKey: "cameraDefaultMainLens") ?? "") else { return 1 }
        let factor = mm / main
        return factors(main: main, maximum: maximum, defaults: defaults).contains(where: { abs($0 - factor) < 0.001 }) ? factor : 1
    }
    static func next(after value: Double, main: Double?, maximum: Double, defaults: UserDefaults = .standard) -> Double {
        let options = factors(main: main, maximum: maximum, defaults: defaults)
        guard let index = options.firstIndex(where: { abs($0 - value) < 0.025 }) else { return 1 }
        return options[(index + 1) % options.count]
    }
}

struct MainCameraSettingsView: View {
    @ObservedObject var camera: DualCamera
    @AppStorage("cameraMainLens28") private var lens28 = CameraDefaults.bool("cameraMainLens28")
    @AppStorage("cameraMainLens35") private var lens35 = CameraDefaults.bool("cameraMainLens35")
    @AppStorage("cameraDefaultMainLens") private var defaultLens = CameraDefaults.string("cameraDefaultMainLens")
    private var focal: CameraFocalCalibration? { CameraFocalCalibration.known(CaptureDeviceInfo.current.hardwareIdentifier) }
    private var canCrop: Bool { focal.map { $0.main < 28 } ?? false }
    private var lenses: [CameraLensDescription] { CameraLensDescription.detected() }
    private var nativeTitle: String { focal.map { "\(Int($0.main)) mm · 1×" } ?? "1×" }
    var body: some View {
        List {
            Section {
                ForEach(lenses) { lens in
                    HStack {
                        Label(L10n.text(lens.title), systemImage: lens.front ? "person.crop.square" : "camera.aperture")
                        Spacer()
                        if let mm = millimeters(lens) { Text("\(Int(mm)) mm").foregroundStyle(.secondary) }
                    }
                }
                if lenses.isEmpty { Text(L10n.text("未检测到摄像头")) }
            } header: { Text(L10n.text("已检测镜头")) } footer: {
                Text(L10n.text("实际可用镜头与倍率会随单摄、双摄及录制规格调整。"))
            }
            if canCrop {
                Section {
                    Toggle("28 mm", isOn: $lens28).accessibilityIdentifier("mainLens28").tint(.green)
                    Toggle("35 mm", isOn: $lens35).accessibilityIdentifier("mainLens35").tint(.green)
                } header: { Text(L10n.text("更多取景档位")) } footer: {
                    Text(L10n.text("28 mm 和 35 mm 使用主摄裁切取景，不是额外的物理镜头。拍照时轻点当前主摄倍率可循环切换。"))
                }
            }
            Section {
                choice("native", title: nativeTitle)
                if canCrop, lens28 { choice("28", title: "28 mm") }
                if canCrop, lens35 { choice("35", title: "35 mm") }
            } header: { Text(L10n.text("默认取景")) } footer: {
                Text(L10n.text("进入后置拍照时使用此档位。仅影响 ArkCam，不修改系统相机设置。"))
            }
        }
        .navigationTitle(L10n.text("主相机")).navigationBarTitleDisplayMode(.inline)
        .onChange(of: lens28) { _, enabled in if !enabled && defaultLens == "28" { defaultLens = "native" } }
        .onChange(of: lens35) { _, enabled in if !enabled && defaultLens == "35" { defaultLens = "native" } }
    }
    private func choice(_ id: String, title: String) -> some View {
        Button { defaultLens = id } label: {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); if defaultLens == id { Image(systemName: "checkmark").foregroundStyle(.yellow) } }
        }.accessibilityIdentifier("defaultMainLens-" + id)
    }
    private func millimeters(_ lens: CameraLensDescription) -> Double? {
        guard !lens.front else { return nil }
        switch lens.type { case .builtInUltraWideCamera: return focal?.ultraWide
        case .builtInTelephotoCamera: return focal?.telephoto
        default: return focal?.main }
    }
}

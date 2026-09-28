import Foundation

// Apple Support specifications, matched to Apple's installed simulator model
// identifiers. See docs/IPHONE_CAMERA_REFERENCE_20260918.md. These are product
// ceilings and labels only; never a replacement for AVFoundation discovery.
struct CameraModelReference {
    let photo: Double
    let video: Double
    let focal: CameraFocalCalibration?
    static let known: [String: Self] = [
        "iPhone18,2": .init(photo: 40, video: 15, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 100)), // iPhone 17 Pro Max; https://support.apple.com/en-us/125091
        "iPhone18,1": .init(photo: 40, video: 15, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 100)), // iPhone 17 Pro; https://support.apple.com/en-us/125090
        "iPhone18,3": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 17; https://support.apple.com/en-us/125089
        "iPhone18,4": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: nil, telephoto: nil)), // iPhone Air; https://support.apple.com/en-us/125092
        "iPhone17,5": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: nil, telephoto: nil)), // iPhone 16e; https://support.apple.com/en-us/122208
        "iPhone17,2": .init(photo: 25, video: 15, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 120)), // iPhone 16 Pro Max; https://support.apple.com/en-us/121032
        "iPhone17,1": .init(photo: 25, video: 15, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 120)), // iPhone 16 Pro; https://support.apple.com/en-us/121031
        "iPhone17,4": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 16 Plus; https://support.apple.com/en-us/121030
        "iPhone17,3": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 16; https://support.apple.com/en-us/121029
        "iPhone16,2": .init(photo: 25, video: 15, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 120)), // iPhone 15 Pro Max; https://support.apple.com/en-us/111828
        "iPhone16,1": .init(photo: 15, video: 9, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 77)), // iPhone 15 Pro; https://support.apple.com/en-us/111829
        "iPhone15,5": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 15 Plus; https://support.apple.com/en-us/111830
        "iPhone15,4": .init(photo: 10, video: 6, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 15; https://support.apple.com/en-us/111831
        "iPhone15,3": .init(photo: 15, video: 9, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 77)), // iPhone 14 Pro Max; https://support.apple.com/en-us/111846
        "iPhone15,2": .init(photo: 15, video: 9, focal: CameraFocalCalibration(main: 24, ultraWide: 13, telephoto: 77)), // iPhone 14 Pro; https://support.apple.com/en-us/111849
        "iPhone14,8": .init(photo: 5, video: 3, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 14 Plus; https://support.apple.com/en-us/111854
        "iPhone14,7": .init(photo: 5, video: 3, focal: CameraFocalCalibration(main: 26, ultraWide: 13, telephoto: nil)), // iPhone 14; https://support.apple.com/en-us/111850
        "iPhone14,6": .init(photo: 5, video: 3, focal: nil), // iPhone SE (3rd generation); https://support.apple.com/en-us/111866
        "iPhone14,3": .init(photo: 15, video: 9, focal: nil), // iPhone 13 Pro Max; https://support.apple.com/en-us/111870
        "iPhone14,2": .init(photo: 15, video: 9, focal: nil), // iPhone 13 Pro; https://support.apple.com/en-us/111871
        "iPhone14,5": .init(photo: 5, video: 3, focal: nil), // iPhone 13; https://support.apple.com/en-us/111872
        "iPhone14,4": .init(photo: 5, video: 3, focal: nil), // iPhone 13 mini; https://support.apple.com/en-us/111873
        "iPhone13,4": .init(photo: 12, video: 7, focal: nil), // iPhone 12 Pro Max; https://support.apple.com/en-us/111874
        "iPhone13,3": .init(photo: 10, video: 6, focal: nil), // iPhone 12 Pro; https://support.apple.com/en-us/111875
        "iPhone13,2": .init(photo: 5, video: 3, focal: nil), // iPhone 12; https://support.apple.com/en-us/111876
        "iPhone13,1": .init(photo: 5, video: 3, focal: nil), // iPhone 12 mini; https://support.apple.com/en-us/111877
        "iPhone12,8": .init(photo: 5, video: 3, focal: nil), // iPhone SE (2nd generation); https://support.apple.com/en-us/111882
        "iPhone12,3": .init(photo: 10, video: 6, focal: nil), // iPhone 11 Pro; https://support.apple.com/en-us/111879
        "iPhone12,5": .init(photo: 10, video: 6, focal: nil), // iPhone 11 Pro Max; https://support.apple.com/en-us/111878
        "iPhone12,1": .init(photo: 5, video: 3, focal: nil), // iPhone 11; https://support.apple.com/en-us/111865
        "iPhone11,2": .init(photo: 10, video: 6, focal: nil), // iPhone XS; https://support.apple.com/en-us/111881
        "iPhone11,4": .init(photo: 10, video: 6, focal: nil), // iPhone XS Max; https://support.apple.com/en-us/111880
        "iPhone11,8": .init(photo: 5, video: 3, focal: nil), // iPhone XR; https://support.apple.com/en-us/111868
    ]
}

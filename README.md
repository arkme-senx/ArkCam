# ArkCam

ArkCam 是一款 iOS 双面相机：同时使用前后摄像头拍摄，保留两路原片，并可将主画面与小窗合成为一份照片、Live Photo 或视频保存到系统相册。默认后摄为主画面、前摄为小窗；拍摄后可在 App 内调整布局。本仓库供团队继续开发、测试和准备 App Store 上架。

**当前状态：** `0.1.0 (56)` 是开发测试构建，不是已通过 App Store 验收的版本。锁屏右下角“双面拍摄”入口的自动取景问题已在 iOS 27 / iPhone 15 Pro Max 上修复并完成一次真机拍照验证；历史锁屏素材移交完整性、更多设备与最终分发包仍需复核。详情见[锁屏修复验证记录](docs/LOCKSCREEN-VALIDATION-2026-09-28.md)。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `Cam/` | SwiftUI 主 App、AVFoundation 双摄采集、回忆库、播放与导出 |
| `Shared/` | 主 App 与扩展共用的设置、拍摄意图和本地化资源 |
| `CamCapture/` | 锁屏拍摄扩展 |
| `CamControls/` | 锁屏与控制中心的“双面拍摄”控制 |
| `CamTests/`、`CamUITests/` | 单元和界面测试 |
| `scripts/` | Xcode 工程、本地化及媒体检查工具 |
| `website-prototype/` | 独立静态官网样稿；预约表单不会提交数据 |

## 构建

在 macOS 上使用 Xcode 27 打开 `Cam.xcodeproj`，选择 `Cam` scheme。主 App 最低支持 iOS 17；系统控制和锁屏拍摄扩展最低支持 iOS 18。模拟器可用于界面与非相机逻辑测试，**不能**验证前后双摄或真正的锁屏拍摄。

```sh
xcodebuild -project Cam.xcodeproj -scheme Cam \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

真机开发安装需为主 App、`CamControls` 和 `CamCapture` 三个目标配置同一 Apple 开发团队及对应 Bundle ID。工程保留官方 Bundle ID `com.tison.dualcam` 及团队的开发设置；外部贡献者应改用**自己的**团队和三个唯一 Bundle ID，避免与正式 ArkCam 安装互相覆盖。`scripts/generate_project.rb` 依赖 Ruby `xcodeproj` gem；重新生成工程前请检查其中的版本、签名和目标设置。

## 数据与测试边界

回忆原片保存在 App 私有容器的 `Application Support/Cam/Memories`。App 不主动上传影像；系统相册中的合成成片与 App 内两路原片是不同副本。卸载 App 或更换签名团队可能使私有原片无法通过普通更新保留，操作前应备份并核验。锁屏扩展使用系统提供的本次拍摄会话目录，历史回忆由主 App 管理。

提交变更时请说明测试设备、iOS 版本、构建号，以及验证级别（编译、模拟器、真机、锁屏或 App Store）。任何涉及存储、导入和签名的改动都应检查两路原片和已有素材的完整性。

源码按 [MIT License](LICENSE) 发布。ArkCam 名称和标识的使用边界见 [TRADEMARKS.md](TRADEMARKS.md)。用户协议和隐私政策由实际运营主体另行审核、发布；它们不由本源码许可证替代。

继续开发前可读[产品设计与实现边界](docs/PRODUCT.md)；准备上架时使用[交付检查](docs/RELEASING.md)。

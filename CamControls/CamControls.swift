import AppIntents
import SwiftUI
import WidgetKit

@main
struct CamControls: WidgetBundle {
    var body: some Widget { CamCaptureControl() }
}

struct CamCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.tison.dualcam.capture") {
            ControlWidgetButton(action: CamCaptureIntent()) {
                Label("双面拍摄", systemImage: "camera.on.rectangle")
            }
        }
        .displayName("双面拍摄")
        .description("打开双面 Cam，拍下眼前和镜头后的你。")
    }
}

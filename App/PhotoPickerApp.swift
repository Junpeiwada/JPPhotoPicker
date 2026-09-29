import SwiftUI
import PhotoPickerCore

@main
struct PhotoPickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: BrowserModel

    init() {
        let m = BrowserModel()
        _model = State(initialValue: m)
        AppDelegate.model = m   // 終了時の確認（実行中の適用・取り消し）から参照する
    }

    var body: some Scene {
        Window("PhotoPicker", id: "main") {
            BrowserView()
                .environment(model)
                .task {
                    #if DEBUG
                    // 開発用: `-openFolder <パス>` / `-debugScript` は一度だけ実行する（.task の再実行で置き換えない）
                    DebugScript.startOnce(model: model)
                    #endif
                }
        }
        .defaultSize(width: 1280, height: 860)
        .commands { BrowserCommands() }

        Settings {
            SettingsView()
        }
    }
}

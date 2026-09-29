import SwiftUI

/// UserDefaults のキー
enum PreferenceKey {
    /// 大プレビューを前後それぞれ何枚先読みするか
    static let prefetchCount = "prefetchCount"
    /// フォーカス枠を表示するか
    static let showFocusFrame = "showFocusFrame"

    static let defaultPrefetchCount = 4

    static func register() {
        UserDefaults.standard.register(defaults: [
            prefetchCount: defaultPrefetchCount,
            showFocusFrame: true,
        ])
    }
}

/// 設定画面（⌘,）
struct SettingsView: View {
    @AppStorage(PreferenceKey.prefetchCount) private var prefetchCount = PreferenceKey.defaultPrefetchCount

    var body: some View {
        Form {
            Section {
                Stepper(value: $prefetchCount, in: 0...12) {
                    LabeledContent("先読み枚数") {
                        Text("前後それぞれ \(prefetchCount) 枚")
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("大プレビューを、今のコマの前後それぞれ何枚先読みするかを指定します。増やすとコマ送りが速くなりますが、メモリを多く使います。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

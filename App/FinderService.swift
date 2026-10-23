import AppKit

/// Finder でフォルダを右クリックしたときの「JPPhotoPicker で開く」（macOS のサービス）。
/// メニューの宣言は project.yml の `NSServices`（表記は App/Resources/*.lproj/ServicesMenu.strings）。
extension AppDelegate {
    /// 起動完了より前に登録しておかないと、右クリックから起動されたときの依頼を受け損なう
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        // 入れ直した直後でもメニューに出るよう、サービスの一覧を更新させる
        NSUpdateDynamicServices()
    }

    /// `NSServices` の `NSMessage: openFolder` に対応する。ドロップと同じ経路で開く
    /// （操作を受け付けない間は開かない）。サービスはアプリを前に出さないので、ここで前に出す
    @objc func openFolder(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let model = Self.model, !urls.isEmpty else {
            error.pointee = "No folder was passed."
            return
        }
        NSApp.activate()
        model.open(dropped: urls)
        Self.showMainWindowIfNeeded()
    }

    /// 右クリックから起動されたときは SwiftUI が最初のウインドウを作らない（既定の起動ではないため）。
    /// モデルはフォルダを開いても画面には何も出ないので、Dock アイコンを押したときと同じ
    /// 再オープンを自分に送ってウインドウを出させる
    private static func showMainWindowIfNeeded() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

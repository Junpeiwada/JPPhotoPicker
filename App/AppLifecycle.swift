import SwiftUI
import AppKit

/// 適用・取り消しの実行中に、終了（⌘Q）で中途半端にならないよう確認する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// JPPhotoPickerApp が作ったモデル（アプリにつき 1 つ）
    static var model: BrowserModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ファイルの移動を実行中です"
        alert.informativeText = "\(model.busyMessage ?? "処理中です。")\n今終了すると、移動が途中で止まります。処理が終わってから終了しますか？"
        alert.addButton(withTitle: "終わってから終了")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // 完了したら終了を続ける（終了処理で保留中の保存も書き出される）
        model.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// メインウインドウの `windowShouldClose` を差し込み、実行中は閉じさせない。
/// SwiftUI が持つ元のデリゲートには、他のメッセージをそのまま転送する。
struct WindowCloseGuard: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let model = model
        // ウインドウに載るのは次のランループ以降
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainActor.assumeIsolated { WindowCloseProxy.install(on: window, model: model) }
        }
    }
}

@MainActor
private final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private static var proxies: [ObjectIdentifier: WindowCloseProxy] = [:]

    private let model: BrowserModel
    nonisolated(unsafe) private var original: NSWindowDelegate?

    private init(model: BrowserModel, original: NSWindowDelegate?) {
        self.model = model
        self.original = original
    }

    static func install(on window: NSWindow, model: BrowserModel) {
        let key = ObjectIdentifier(window)
        if proxies[key] != nil, window.delegate === proxies[key] { return }
        let proxy = WindowCloseProxy(model: model, original: window.delegate)
        proxies[key] = proxy
        window.delegate = proxy
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isBusy {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ファイルの移動を実行中です"
            alert.informativeText = "\(model.busyMessage ?? "処理中です。")\n終わってから閉じてください。"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        let shouldClose = original?.windowShouldClose?(sender) ?? true
        // 閉じる前に、保留中の判定と再開位置を書く
        if shouldClose { model.flushSave() }
        return shouldClose
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || ((original as? NSObject)?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let o = original as? NSObject, o.responds(to: aSelector) { return o }
        return super.forwardingTarget(for: aSelector)
    }
}

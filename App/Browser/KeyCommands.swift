import SwiftUI
import PhotoPickerCore

extension FocusedValues {
    /// メインウインドウがキーのときだけ、そのウインドウの BrowserModel が入る
    @Entry var browserModel: BrowserModel?
}

/// メニューバーに並べるキー操作。単キー（P / X / U / Z / F など）もメニュー項目の
/// キーボードショートカットとして受け、メニューから発見できるようにする。
///
/// モデルは `@FocusedValue` で受けるので、メインウインドウ以外（設定・シート・パネル）がキーのときは
/// 項目が無効になり、単キー・矢印キーは通常どおりそのウインドウへ届く。
/// 無効化の条件は「写真があるか・処理中か・ダイアログ表示中か」を基本にして、
/// 判定のたびにメニューが再評価されないようにする（細かい可否は処理側で無視する）。
/// 例外として、取り消し・やり直し（canUndo / canRedo）と適用（canApply）だけは可否を観測する。
struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    /// 写真の操作を受け付けるか
    private var canOperate: Bool {
        guard let model else { return false }
        return model.hasEntries && !model.isBusy && !model.isModalPresented
    }

    var body: some Commands {
        // ファイル: ⌘O。1 ウインドウ構成なので「新規」は置き換える
        CommandGroup(replacing: .newItem) {
            Button("フォルダを開く…") { model?.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil || model?.isBusy == true || model?.isModalPresented == true)
        }

        // 編集: ⌘Z / ⇧⌘Z（判定の取り消し / やり直し）
        CommandGroup(replacing: .undoRedo) {
            Button("判定を取り消す") { model?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canOperate || model?.canUndo != true)
            Button("判定をやり直す") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canOperate || model?.canRedo != true)
        }

        CommandMenu("選別") {
            Button("採用") { model?.toggleDecision(.picked) }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!canOperate)
            Button("不採用") { model?.toggleDecision(.rejected) }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!canOperate)
            Button("判定を解除") { model?.clearDecision() }
                .keyboardShortcut("u", modifiers: [])
                .disabled(!canOperate)

            Divider()

            Button("前の写真") { model?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!canOperate)
            Button("次の写真") { model?.next() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canOperate)
            Button("前のグループ") { model?.previousGroup() }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(!canOperate)
            Button("次のグループ") { model?.nextGroup() }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(!canOperate)

            Divider()

            Button("適用…") { model?.requestApply() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canOperate || model?.canApply != true)
            Button("適用を取り消す…") { model?.requestUndoApply() }
                .disabled(model == nil || model?.canUndoApply != true || model?.isModalPresented == true)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("拡大を切り替え") { model?.toggleZoom() }
                .keyboardShortcut("z", modifiers: [])
                .disabled(!canOperate)
            Button("全体表示に戻す") { model?.resetZoom() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!canOperate)
            Button("フォーカス位置へ") { model?.moveToFocus() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!canOperate)
            Toggle("フォーカス枠を表示", isOn: Binding(
                get: { model?.showFocusFrame ?? true },
                set: { model?.showFocusFrame = $0 }))
                .keyboardShortcut("f", modifiers: .shift)
                .disabled(model == nil || model?.isModalPresented == true)
        }
    }
}

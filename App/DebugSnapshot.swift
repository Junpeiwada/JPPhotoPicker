#if DEBUG
import AppKit

/// 開発用: `-debugScript "wait,z,next,snap:/path.png"` で操作を再生してウインドウ画像を保存する。
@MainActor
enum DebugScript {
    private static var started = false

    /// `-openFolder` と `-debugScript` を、プロセスにつき一度だけ実行する
    static func startOnce(model: BrowserModel) {
        guard !started else { return }
        started = true
        if let path = UserDefaults.standard.string(forKey: "openFolder") {
            model.open(folder: URL(fileURLWithPath: path))
        }
        runIfNeeded(model: model)
    }

    private static func runIfNeeded(model: BrowserModel) {
        guard let script = UserDefaults.standard.string(forKey: "debugScript") else { return }
        Task { @MainActor in
            for step in script.split(separator: ",").map(String.init) {
                switch step {
                case "wait": try? await Task.sleep(for: .seconds(2))
                case "next": model.next()
                case "prev": model.previous()
                case "nextGroup": model.nextGroup()
                case "z": model.toggleZoom()
                case "esc": model.resetZoom()
                case "f": model.moveToFocus()
                case "i": model.toggleInfo()
                case "p": model.toggleDecision(.picked)
                case "x": model.toggleDecision(.rejected)
                case "undo": model.undo()
                case "apply": model.requestApply()
                case "confirmApply": if let plan = model.pendingApplyPlan { model.confirmApply(plan) }
                case "ok": model.notice = nil; model.failureReport = nil
                case "quit": NSApp.terminate(nil)
                case "undoApply": model.requestUndoApply()
                case "confirmUndoApply": if let r = model.pendingUndoRecord { model.confirmUndoApply(r) }
                default:
                    if step.hasPrefix("open:") { model.open(folder: URL(fileURLWithPath: String(step.dropFirst(5)))) }
                    if step.hasPrefix("goto:") { model.select(id: String(step.dropFirst(5))) }
                    if step.hasPrefix("log:") { log(String(step.dropFirst(4)), model: model) }
                    if step.hasPrefix("snap:") { snapshot(String(step.dropFirst(5))) }
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    /// 状態を 1 行、ファイルに追記する
    private static func log(_ path: String, model: BrowserModel) {
        let line = "entries=\(model.entries.count) current=\(model.currentItem?.id ?? "-") progress=[\(model.progressText)] "
            + "notice=[\((model.notice ?? "").replacingOccurrences(of: "\n", with: " / "))] "
            + "plan=\(model.pendingApplyPlan?.candidates.count ?? -1) undoRecord=\(model.pendingUndoRecord != nil) "
            + "canUndoApply=\(model.canUndoApply) failure=\(model.failureReport?.summary ?? "-") "
            + "canApply=\(model.canApply) topInset=\(model.topInset) view=\(Int(model.viewSize.width))x\(Int(model.viewSize.height)) "
            + "zoomFit=\(model.zoom.isFit) info=\(model.showInfo) infoRows=\(model.currentItem.flatMap { model.infoCache[$0.id] }.map { $0.sections.reduce(0) { $0 + $1.rows.count } } ?? -1) readOnly=\(model.isSessionReadOnly) saveFailed=\(model.saveFailed)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func snapshot(_ path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

import Foundation
import Synchronization
import PhotoPickerCore

/// 保存を直列化する。すべての書き込みが同じロックの下で行われ、世代番号が古い内容は書かない
/// （デバウンス中の保存と、終了時・適用直後の即時保存が前後しても、古い内容が後から勝たない）。
final class SessionSaver: Sendable {
    private let store: SessionStore
    private let lastWritten = Mutex<Int>(0)

    init(store: SessionStore) {
        self.store = store
    }

    /// 書き込む。より新しい世代がすでに書かれていれば何もしない。
    func write(_ data: SessionData, generation: Int) throws {
        try lastWritten.withLock { last in
            guard generation > last else { return }
            try store.save(data)
            last = generation
        }
    }
}

/// フォルダを開いたときの読み込み結果
struct FolderLoadOutcome: Sendable {
    var groups: [PhotoGroup] = []
    var session = SessionData()
    /// フォルダの走査に失敗したときのメッセージ
    var scanError: String?
    /// 保存ファイルについての警告（アラートで必ず知らせる）
    var sessionWarning: String?
    /// 保存してはいけないセッションか（壊れたファイルを退避できなかった・新しい版で作られた・読めなかった）
    var readOnly = false
    /// 前回の適用のジャーナルの確認結果（復旧した記録・壊れていた・読めなかった）
    var recovery: JournalRecovery = .none
}

/// 協調プールを占有しない（`@concurrent`）読み込み・書き込み
enum SessionIO {
    /// 走査 → メタデータ → グループ化 → 保存ファイルの読み込み → ジャーナルの復旧確認。キャンセルされたら nil。
    @concurrent
    static func load(folder: URL, store: SessionStore) async -> FolderLoadOutcome? {
        var out = FolderLoadOutcome()
        do {
            try Task.checkCancellation()
            let scanned = try FolderScanner.scan(folder: folder)
            let items = await PhotoMetadataLoader.load(items: scanned)
            try Task.checkCancellation()
            out.groups = BurstGrouper.group(items)
        } catch is CancellationError {
            return nil
        } catch {
            out.scanError = "フォルダを読み込めませんでした: \(error.localizedDescription)"
            return out
        }

        do {
            out.session = try store.load()
            if out.session.version > SessionData.currentVersion {
                out.readOnly = true
                out.sessionWarning = SessionStoreError
                    .unsupportedVersion(found: out.session.version, supported: SessionData.currentVersion)
                    .localizedDescription + "このフォルダは読み取り専用で開きます（判定は保存されません）。"
            }
        } catch let e as SessionStoreError {
            out.session = SessionData()
            switch e {
            case .corrupted(let backup, _):
                // 退避できたときだけ、以後の保存を許す（退避できないまま上書きすると元のファイルが失われる）
                out.readOnly = backup == nil
                out.sessionWarning = (e.errorDescription ?? "") + (backup == nil
                    ? "壊れたファイルを守るため、このフォルダでは判定を保存しません。"
                    : "判定なしで開きました。")
            case .unsupportedVersion:
                out.readOnly = true
                out.sessionWarning = (e.errorDescription ?? "") + "このフォルダは読み取り専用で開きます。"
            }
        } catch {
            out.session = SessionData()
            out.readOnly = true
            out.sessionWarning = "\(SessionStore.fileName) を読めませんでした（\(error.localizedDescription)）。"
                + "元のファイルを守るため、このフォルダでは判定を保存しません。"
        }

        if !Task.isCancelled {
            out.recovery = ApplyEngine(folder: folder).recoverJournal()
        }
        return out
    }

    /// デバウンス後の保存。失敗したらそのエラーを返す。
    @concurrent
    static func write(_ saver: SessionSaver, _ data: SessionData, generation: Int) async -> (any Error)? {
        do { try saver.write(data, generation: generation); return nil } catch { return error }
    }

    @concurrent
    static func apply(folder: URL, plan: ApplyPlan) async -> ApplyResult {
        ApplyEngine(folder: folder).apply(plan)
    }

    @concurrent
    static func undo(folder: URL, record: ApplyRecord) async -> UndoResult {
        ApplyEngine(folder: folder).undo(record)
    }
}

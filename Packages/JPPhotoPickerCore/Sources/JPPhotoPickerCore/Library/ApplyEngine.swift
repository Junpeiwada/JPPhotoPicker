import Foundation

/// 移動予定（確認ダイアログに出す内容）
public struct ApplyPlan: Sendable, Equatable {
    /// 移すコマ（グループの並び順）
    public let candidates: [MoveCandidate]

    public init(candidates: [MoveCandidate]) {
        self.candidates = candidates
    }

    /// 移す JPG の枚数
    public var jpgCount: Int { candidates.filter { $0.jpgURL != nil }.count }
    /// 移す ARW の枚数（ペアの ARW も含む）
    public var arwCount: Int { candidates.filter { $0.arwURL != nil }.count }
    /// 移すファイルの一覧（JPG、ARW の順にコマごと）
    var files: [URL] { candidates.flatMap(\.urls) }
    public var isEmpty: Bool { candidates.isEmpty }
}

/// 飛ばした（失敗した）ファイル 1 件
public struct ApplyFailure: Sendable, Equatable, Hashable {
    /// フォルダからの相対パス（移動のときは元の場所、取り消しのときは `_rejected/...`）
    public let path: String
    /// 日本語の理由（ユーザーに見せてよい文）
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// `apply` の結果
public struct ApplyResult: Sendable, Equatable {
    /// 成功した移動の記録。1 件も移せなかったときは nil
    public let record: ApplyRecord?
    public let failures: [ApplyFailure]
    let movedJPGCount: Int
    let movedARWCount: Int

    public var movedCount: Int { record?.moves.count ?? 0 }
}

/// `undo` の結果
public struct UndoResult: Sendable, Equatable {
    /// 戻せた件数
    public let restoredCount: Int
    public let failures: [ApplyFailure]
    /// 戻せなかった移動だけを残した記録。全部戻せたら nil（記録ごと取り除いてよい）
    public let remainingRecord: ApplyRecord?
}

extension SessionData {
    /// 適用の記録を末尾に追加する（`apply` の結果の `record`、または `ApplyEngine.recoverJournal()` の結果を渡す）。
    /// 同じ `id` の記録が既にあれば追加しない（復旧の二重取り込みを防ぐ）。追加したら true。
    @discardableResult
    public mutating func appendApplied(_ record: ApplyRecord) -> Bool {
        guard !applied.contains(where: { $0.id == record.id }) else { return false }
        applied.append(record)
        return true
    }

    /// 取り消しの結果を反映する。全部戻せたら記録を取り除き、一部だけなら残った移動だけの記録に置き換える。
    /// 記録を `id` で探し、見つからなければ何もせず false を返す。
    @discardableResult
    public mutating func finishUndo(of record: ApplyRecord, result: UndoResult) -> Bool {
        guard let i = applied.firstIndex(where: { $0.id == record.id }) else { return false }
        if let remaining = result.remainingRecord {
            applied[i] = remaining
        } else {
            applied.remove(at: i)
        }
        return true
    }
}

/// `ApplyEngine.recoverJournal()` の結果
public enum JournalRecovery: Sendable, Equatable {
    /// ジャーナルが無い、または復旧できる移動が無かった
    case none
    /// 復旧した記録（呼び出し側が `appendApplied` → 保存 → `clearJournal()` する）
    case recovered(ApplyRecord)
    /// ジャーナルが壊れていたので退避した（取り消せない適用があるかもしれない）
    case broken(backup: URL)
    /// ジャーナルを読めない・退避できないなど。理由は日本語
    case unreadable(String)
}

/// 適用の途中経過（`_rejected/.jpphotopicker-apply-journal.json`）
struct ApplyJournal: Codable, Equatable {
    var id: UUID
    var date: Date
    /// 移し終えたことを確認した移動
    var moves: [MoveRecord]
    /// 次のバッチで移す予定の移動（クラッシュ時は、移動先があり元が無いものだけを移動済みとみなす）
    var pending: [MoveRecord]
}

/// 適用（`_rejected/` への一括移動）と取り消し。
/// `SessionStore` は触らない。呼び出し側が結果の `record` を `SessionData.appendApplied` で追記して保存する。
/// 同期 API。UI からはバックグラウンドで呼ぶこと。
///
/// 適用中は `_rejected/.jpphotopicker-apply-journal.json` に移動の記録を書き続ける。
/// 正常終了後もジャーナルは残る。呼び出し側は `record` を SessionData に取り込んで保存した後で `clearJournal()` を呼ぶこと。
/// 適用の途中でアプリが落ちたときは、次にフォルダを開いたときに `recoverJournal()` で記録を復旧できる。
public struct ApplyEngine: Sendable {
    public static let rejectedFolderName = "_rejected"
    public static let journalFileName = ".jpphotopicker-apply-journal.json"
    /// ジャーナルを書き出す間隔（移動の件数）
    static let journalBatchSize = 32

    public let folder: URL
    /// ファイルの移動（テストで失敗を起こすために差し替える）。適用・取り消しの両方で使う
    var mover: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    public init(folder: URL) {
        self.folder = folder
    }

    public var rejectedFolder: URL { folder.appendingPathComponent(Self.rejectedFolderName, isDirectory: true) }
    public var journalURL: URL { rejectedFolder.appendingPathComponent(Self.journalFileName) }

    /// 移動予定を作る（ファイルには触らない）
    public static func plan(groups: [PhotoGroup], decisions: [String: Decision]) -> ApplyPlan {
        ApplyPlan(candidates: DecisionRules.moveCandidates(groups: groups, decisions: decisions))
    }

    /// ペアの相手の名前（「ARW」「JPG」）
    private static func pairName(of w: WorkItem) -> String {
        w.isJPG ? "ARW" : "JPG"
    }

    /// 相手を移せなかったので `w` も移さなかった、という理由
    private static func pairNotMoved(_ w: WorkItem) -> String {
        "ペアの \(pairName(of: w)) を移せなかったため \(w.isJPG ? "JPG" : "ARW") も移しませんでした"
    }

    private struct WorkItem {
        let url: URL
        let name: String
        let isJPG: Bool
    }

    /// 予定どおり `_rejected/` に移す。同名のファイルがある・失敗したファイルは飛ばして失敗一覧に入れる（上書きしない）。
    /// JPG と ARW のペアは必ずそろって移す。片方を移せなかったら、先に移した方を戻してペアごと失敗にする。
    /// 戻せなかったときは、移ったままの方を記録に残して失敗一覧に明記する（取り消しで戻せる）。
    /// 予定の URL がフォルダ直下のファイルでなければ、そのファイルは失敗扱いにする。
    /// 残っているジャーナル（前回の適用の復旧漏れ）があるときは、何も移さず全件失敗にする。
    public func apply(_ plan: ApplyPlan) -> ApplyResult {
        let fm = FileManager.default
        var failures: [ApplyFailure] = []
        var moves: [MoveRecord] = []
        var jpgs = 0, arws = 0
        guard !plan.isEmpty else { return ApplyResult(record: nil, failures: [], movedJPGCount: 0, movedARWCount: 0) }

        func failAll(_ reason: String) -> ApplyResult {
            ApplyResult(record: nil,
                        failures: plan.files.map { ApplyFailure(path: $0.lastPathComponent, reason: reason) },
                        movedJPGCount: 0, movedARWCount: 0)
        }

        if fm.fileExists(atPath: journalURL.path) {
            return failAll("前回の適用の記録が残っています。フォルダを開き直して記録を取り込んでください")
        }
        do {
            try fm.createDirectory(at: rejectedFolder, withIntermediateDirectories: true)
        } catch {
            return failAll("\(Self.rejectedFolderName) を作れませんでした: \(error.localizedDescription)")
        }

        guard isRejectedFolderInsideFolder() else {
            return failAll("\(Self.rejectedFolderName) がフォルダの外を指しているため中止しました")
        }

        // 1 コマ = 1 単位。JPG と ARW のペアは同じ単位で、必ずそろって移す
        var units: [[WorkItem]] = []
        for c in plan.candidates {
            let unit = [(c.jpgURL, true), (c.arwURL, false)].compactMap { u, j in
                u.map { WorkItem(url: $0, name: $0.lastPathComponent, isJPG: j) }
            }
            if !unit.isEmpty { units.append(unit) }
        }

        var journal = ApplyJournal(id: UUID(), date: Date(), moves: [], pending: [])
        let batch = Self.journalBatchSize

        func record(_ w: WorkItem) {
            moves.append(MoveRecord(from: w.name, to: "\(Self.rejectedFolderName)/\(w.name)"))
            if w.isJPG { jpgs += 1 } else { arws += 1 }
        }

        var u = 0
        while u < units.count {
            // バッチの先頭: これから移す予定（ファイル数が batch に達するまでのコマ）を先に書き出す
            var end = u
            var count = 0
            while end < units.count, count < batch {
                count += units[end].count
                end += 1
            }
            journal.moves = moves
            journal.pending = units[u..<end].flatMap { $0 }
                .filter { isEligible($0) }
                .map { MoveRecord(from: $0.name, to: "\(Self.rejectedFolderName)/\($0.name)") }
            do {
                try writeJournal(journal)
            } catch {
                let reason = "適用の記録を書けなかったため中止しました: \(error.localizedDescription)"
                for unit in units[u...] { for w in unit { failures.append(ApplyFailure(path: w.name, reason: reason)) } }
                break
            }

            for unit in units[u..<end] {
                // 先に両方の移動先の衝突・元の存在を確認する
                var problems: [Int: String] = [:]
                for (k, w) in unit.enumerated() {
                    if !(isDirectChild(w.url, of: folder) && Self.isSingleComponent(w.name)) {
                        problems[k] = "フォルダ直下のファイルではありません"
                    } else if !fm.fileExists(atPath: w.url.path) {
                        problems[k] = "元のファイルが見つかりません"
                    } else if Self.exists(rejectedFolder.appendingPathComponent(w.name)) {
                        problems[k] = "\(Self.rejectedFolderName) に同じ名前のファイルがあります"
                    }
                }
                if !problems.isEmpty {
                    for (k, w) in unit.enumerated() {
                        failures.append(ApplyFailure(path: w.name, reason: problems[k] ?? Self.pairNotMoved(w)))
                    }
                    continue
                }
                // 1 つずつ移す。2 つ目が失敗したら 1 つ目を元に戻す
                var done: [WorkItem] = []
                for (k, w) in unit.enumerated() {
                    let dest = rejectedFolder.appendingPathComponent(w.name)
                    do {
                        try mover(w.url, dest)
                        done.append(w)
                    } catch {
                        failures.append(ApplyFailure(path: w.name, reason: error.localizedDescription))
                        for other in unit[(k + 1)...] { failures.append(ApplyFailure(path: other.name, reason: Self.pairNotMoved(other))) }
                        for moved in done {
                            let movedDest = rejectedFolder.appendingPathComponent(moved.name)
                            do {
                                try mover(movedDest, moved.url)
                                failures.append(ApplyFailure(path: moved.name, reason: Self.pairNotMoved(moved)))
                            } catch {
                                // 戻せなかった: 移ってしまったので記録に残し、取り消しで戻せるようにする
                                record(moved)
                                failures.append(ApplyFailure(
                                    path: moved.name,
                                    reason: "ペアの \(Self.pairName(of: moved)) を移せなかったうえ、\(moved.isJPG ? "JPG" : "ARW") を元に戻せませんでした（\(Self.rejectedFolderName) に移ったままです。取り消しで戻せます）: \(error.localizedDescription)"))
                            }
                        }
                        done = []
                        break
                    }
                }
                for w in done { record(w) }
            }
            u = end
        }

        if moves.isEmpty {
            // 1 件も移せなかったのに作った空の _rejected は片付ける
            try? fm.removeItem(at: journalURL)
            removeRejectedFolderIfEmpty()
            return ApplyResult(record: nil, failures: failures, movedJPGCount: 0, movedARWCount: 0)
        }
        journal.moves = moves
        journal.pending = []
        try? writeJournal(journal)   // 最終書き込み。失敗しても record は返す（直前のバッチまでは記録済み）
        let record = ApplyRecord(id: journal.id, date: journal.date, moves: moves)
        return ApplyResult(record: record, failures: failures, movedJPGCount: jpgs, movedARWCount: arws)
    }

    /// 適用の途中経過（ジャーナル）から記録を復旧する。
    ///
    /// 「移動先に存在し、元の場所には無い」移動だけを記録に入れる。結果は `JournalRecovery`:
    /// - `.none`: ジャーナルが無い、または復旧できる移動が 1 件も無かった（ジャーナルは片付け済み）
    /// - `.recovered`: 記録を返す。ジャーナルは残すので、呼び出し側が `SessionData.appendApplied` で取り込んで保存した後に
    ///   `clearJournal()` を呼ぶこと（`appendApplied` は同じ `id` を二重に追加しない）
    /// - `.broken`: ジャーナルが壊れていた。フォルダ直下の `.jpphotopicker-apply-journal.json.broken-…` に退避した
    ///   （`_rejected` の空判定を妨げないよう、`_rejected` の外に置く）。取り消せない適用があるかもしれないので警告すること
    /// - `.unreadable`: ジャーナルを読めない・退避できない・`_rejected` がフォルダの外を指している。ジャーナルは残る
    public func recoverJournal() -> JournalRecovery {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path) else { return .none }
        guard isRejectedFolderInsideFolder() else {
            return .unreadable("\(Self.rejectedFolderName) がフォルダの外を指しているため、適用の記録を確認できません")
        }
        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            return .unreadable("適用の記録を読めませんでした: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(ApplyJournal.self, from: data) else {
            // 壊れたジャーナルは退避して、次回以降の適用を妨げないようにする
            let broken = brokenJournalDestination()
            do {
                try fm.moveItem(at: journalURL, to: broken)
            } catch {
                return .unreadable("壊れた適用の記録を退避できませんでした: \(error.localizedDescription)")
            }
            removeRejectedFolderIfEmpty()
            return .broken(backup: broken)
        }
        var recovered: [MoveRecord] = []
        var seen = Set<String>()
        for mv in journal.moves + journal.pending {
            guard isValidMove(mv), seen.insert(mv.from).inserted,
                  let from = resolve(mv.from), let to = resolve(mv.to) else { continue }
            if fm.fileExists(atPath: to.path), !Self.exists(from) { recovered.append(mv) }
        }
        guard !recovered.isEmpty else {
            clearJournal()
            return .none
        }
        return .recovered(ApplyRecord(id: journal.id, date: journal.date, moves: recovered))
    }

    /// 壊れたジャーナルの退避先（フォルダ直下。既にあれば連番）
    private func brokenJournalDestination() -> URL {
        FileSafety.brokenDestination(for: Self.journalFileName, in: folder)
    }

    /// ジャーナルを削除する（記録を SessionData に保存した後に呼ぶ）。空になった `_rejected` も片付ける。
    public func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
        removeRejectedFolderIfEmpty()
    }

    /// 記録どおり元の場所へ戻す。戻し先に既にファイルがある・失敗したものは飛ばして失敗一覧に入れる。
    /// 記録が「from = フォルダ直下の 1 要素、to = `_rejected/<1 要素>`」の形でないもの、
    /// シンボリックリンクを解いた結果がフォルダの外を指すものは扱わない。
    public func undo(_ record: ApplyRecord) -> UndoResult {
        let fm = FileManager.default
        var failures: [ApplyFailure] = []
        var remaining: [MoveRecord] = []
        var restored = 0

        // _rejected が無いなら、まず「移動後のファイルが見つかりません」を返す（パス検査より前）
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rejectedFolder.path, isDirectory: &isDir), isDir.boolValue else {
            let f = record.moves.map { ApplyFailure(path: $0.to, reason: "移動後のファイルが見つかりません") }
            return UndoResult(restoredCount: 0, failures: f, remainingRecord: record.moves.isEmpty ? nil : record)
        }
        let rejectedFolderIsInside = isRejectedFolderInsideFolder()
        for mv in record.moves {
            guard isValidMove(mv), let from = resolve(mv.from), let to = resolve(mv.to),
                  isDirectChild(from, of: folder), isDirectChild(to, of: rejectedFolder),
                  rejectedFolderIsInside else {
                failures.append(ApplyFailure(path: mv.to, reason: "記録のパスが不正です"))
                remaining.append(mv)
                continue
            }
            if !fm.fileExists(atPath: to.path) {
                failures.append(ApplyFailure(path: mv.to, reason: "移動後のファイルが見つかりません"))
                remaining.append(mv)
                continue
            }
            if Self.exists(from) {
                failures.append(ApplyFailure(path: mv.to, reason: "戻し先に同じ名前のファイルがあります"))
                remaining.append(mv)
                continue
            }
            do {
                try mover(to, from)
                restored += 1
            } catch {
                failures.append(ApplyFailure(path: mv.to, reason: error.localizedDescription))
                remaining.append(mv)
            }
        }

        removeRejectedFolderIfEmpty()
        let rest = remaining.isEmpty ? nil : ApplyRecord(id: record.id, date: record.date, moves: remaining)
        return UndoResult(restoredCount: restored, failures: failures, remainingRecord: rest)
    }

    // MARK: - 内部

    private func isEligible(_ w: WorkItem) -> Bool {
        Self.isSingleComponent(w.name) && isDirectChild(w.url, of: folder)
            && FileManager.default.fileExists(atPath: w.url.path)
            && !Self.exists(rejectedFolder.appendingPathComponent(w.name))
    }

    private func writeJournal(_ journal: ApplyJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    /// 壊れたリンクも「ある」とみなす（`FileSafety.exists`）
    private static func exists(_ url: URL) -> Bool { FileSafety.exists(url) }

    /// 区切り・`.`・`..`・空を含まない 1 要素の名前か
    private static func isSingleComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }

    /// 記録の形の検査: from はフォルダ直下の 1 要素、to は `_rejected/<1 要素>`
    private func isValidMove(_ mv: MoveRecord) -> Bool {
        guard Self.isSingleComponent(mv.from) else { return false }
        let parts = mv.to.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == Self.rejectedFolderName && Self.isSingleComponent(String(parts[1]))
    }

    /// `_rejected` 自体がシンボリックリンクでフォルダの外を指していないか
    private func isRejectedFolderInsideFolder() -> Bool {
        let resolved = rejectedFolder.resolvingSymlinksInPath().standardizedFileURL.path
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(Self.rejectedFolderName).path
        return resolved == expected
    }

    /// `url` の親ディレクトリが（シンボリックリンクを解いて）`dir` と同じか
    private func isDirectChild(_ url: URL, of dir: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let expected = dir.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == expected
    }

    /// 相対パスをフォルダ内の URL にする。`..` や絶対パスは nil
    private func resolve(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        return folder.appendingPathComponent(relative)
    }

    /// `_rejected/` が空（`.DS_Store` だけを含む）なら削除する
    private func removeRejectedFolderIfEmpty() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rejectedFolder.path) else { return }
        guard names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? fm.removeItem(at: rejectedFolder)
    }
}

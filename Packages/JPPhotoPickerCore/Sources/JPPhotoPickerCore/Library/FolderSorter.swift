import Foundation

/// `FolderSorter.sort` の結果
public struct SortResult: Sendable, Equatable {
    /// 成功した移動（from はフォルダ直下の名前、to は `JPG/…` `RAW/…` `Del/…`）
    public let moves: [MoveRecord]
    public let failures: [ApplyFailure]

    /// `JPG/` に入れた枚数
    public var jpgCount: Int { count(FolderSorter.jpgFolderName) }
    /// `RAW/` に入れた枚数
    public var rawCount: Int { count(FolderSorter.rawFolderName) }
    /// `Del/` に入れた枚数（JPG の無い RAW）
    public var orphanCount: Int { count(FolderSorter.orphanFolderName) }

    private func count(_ folder: String) -> Int { moves.filter { $0.to.hasPrefix(folder + "/") }.count }
}

/// 移動の記録を戻した結果（`FolderSorter.undo` と、`ApplyEngine.undo` の `_rejected` の分の両方で使う）
struct MoveUndoResult: Sendable, Equatable {
    let restoredCount: Int
    let failures: [ApplyFailure]
    /// 戻せなかった移動
    let remaining: [MoveRecord]
}

/// 仕分けの途中経過（フォルダ直下の `.jpphotopicker-sort-journal.json`）
struct SortJournal: Codable, Equatable {
    /// 仕分けを足す適用の記録の ID
    var id: UUID
    var date: Date
    /// 移し終えたことを確認した移動
    var moves: [MoveRecord]
    /// 次のバッチで移す予定の移動（クラッシュ時は、移動先があり元が無いものだけを移動済みとみなす）
    var pending: [MoveRecord]
}

/// JPPhotoTools の「取り込み・整理」タブの［仕分けを実行］（RawTrashCore の `RawTrash.sort`）と同じ決まりで、
/// フォルダ直下（再帰しない）のファイルをサブフォルダへ分ける。
///
///   - `JPG/` … すべての JPG（ペアの有無を問わない）
///   - `RAW/` … 同じ名前（拡張子を除き、大文字小文字を無視）の JPG がある RAW
///   - `Del/` … 同じ名前の JPG が無い RAW
///
/// 3 つのフォルダは空でも作る。RAW でも JPG でもないファイルは動かさない。移動先に同じ名前があれば
/// `name_1.ext` のように番号を付ける（JPPhotoTools と同じ）。JPPhotoTools との違いは次のとおり:
///   - 最初の失敗で止まらず、失敗したファイルを飛ばして続け、失敗一覧に入れる
///   - 同じ名前の JPG と RAW はそろって移す（片方を移せなければ、もう片方も直下に戻す）
///   - AppleDouble（`._` で始まる名前）は動かさない
///
/// 移動の記録は `ApplyRecord.sortMoves` に入れ、「適用を取り消す」で元に戻す。仕分け中は
/// `.jpphotopicker-sort-journal.json` に記録を書き続け、落ちたときは次にフォルダを開いたときに `recoverJournal()` で復旧する。
/// 正常終了後もジャーナルは残る。呼び出し側は記録を保存した後で `clearJournal()` を呼ぶこと。
/// 同期 API。UI からはバックグラウンドで呼ぶこと。
public struct FolderSorter: Sendable {
    public static let jpgFolderName = "JPG"
    public static let rawFolderName = "RAW"
    public static let orphanFolderName = "Del"
    public static let folderNames = [jpgFolderName, rawFolderName, orphanFolderName]
    /// JPPhotoTools（`RawTrash.rawExtensions`）と同じ。比較は小文字で行う
    public static let rawExtensions: Set<String> = ["arw", "orf", "cr3", "cr2", "dng"]
    public static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    public static let journalFileName = ".jpphotopicker-sort-journal.json"

    public let folder: URL
    /// ファイルの移動（テストで失敗を起こすために差し替える）。仕分け・取り消しの両方で使う
    var mover: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    public init(folder: URL) {
        self.folder = folder
    }

    public var journalURL: URL { folder.appendingPathComponent(Self.journalFileName) }

    /// 仕分ける。`id` / `date` はジャーナルに書き、復旧したときにどの適用の記録へ足すかに使う。
    /// 残っているジャーナル（前回の仕分けの復旧漏れ）があるときは、何も移さず全件失敗にする。
    public func sort(id: UUID, date: Date) -> SortResult {
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try Self.regularFiles(in: folder)
        } catch {
            return SortResult(moves: [], failures: [ApplyFailure(path: folder.lastPathComponent,
                                                                 reason: "フォルダを読めませんでした: \(error.localizedDescription)")])
        }
        let planned = Self.classify(files)
        func failAll(_ reason: String) -> SortResult {
            SortResult(moves: [], failures: planned.map { ApplyFailure(path: $0.name, reason: reason) })
        }
        if fm.fileExists(atPath: journalURL.path) {
            return failAll("前回の仕分けの記録が残っています。フォルダを開き直して記録を取り込んでください")
        }
        for name in Self.folderNames {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                removeEmptySubfolders()   // 途中まで作った空のフォルダを片付ける
                return failAll("\(name) フォルダを作れませんでした: \(error.localizedDescription)")
            }
            guard isSubfolderInsideFolder(name) else {
                removeEmptySubfolders()
                return failAll("\(name) がフォルダの外を指しているため中止しました")
            }
        }
        guard !planned.isEmpty else { return SortResult(moves: [], failures: []) }

        // 移動先を先に決める（同じ名前があれば番号を付ける。予定どうしでもぶつけない）
        var reserved = Set<String>()
        let work: [MoveRecord] = planned.map { p in
            let dest = uniqueName(for: p.name, in: p.folder, reserved: &reserved)
            return MoveRecord(from: p.name, to: "\(p.folder)/\(dest)")
        }
        let units = Self.pairUnits(work)

        var journal = SortJournal(id: id, date: date, moves: [], pending: [])
        var moves: [MoveRecord] = []
        var failures: [ApplyFailure] = []
        let batch = ApplyEngine.journalBatchSize
        var u = 0
        while u < units.count {
            var end = u
            var count = 0
            while end < units.count, count < batch {
                count += units[end].count
                end += 1
            }
            // 移せないと分かっている移動も pending に入れてよい（復旧は「移動先にあり元に無い」ものだけを拾うため）
            journal.moves = moves
            journal.pending = units[u..<end].flatMap { $0 }
            do {
                try writeJournal(journal)
            } catch {
                let reason = "仕分けの記録を書けなかったため中止しました: \(error.localizedDescription)"
                failures += units[u...].flatMap { $0 }.map { ApplyFailure(path: $0.from, reason: reason) }
                break
            }
            for unit in units[u..<end] {
                let (moved, failed) = moveUnit(unit)
                moves += moved
                failures += failed
            }
            u = end
        }

        if moves.isEmpty {
            try? fm.removeItem(at: journalURL)
            removeEmptySubfolders()
        } else {
            journal.moves = moves
            journal.pending = []
            try? writeJournal(journal)   // 最終書き込み。失敗しても結果は返す（直前のバッチまでは記録済み）
        }
        return SortResult(moves: moves, failures: failures)
    }

    /// 仕分けの途中経過（ジャーナル）から記録を復旧する。「移動先に存在し、元の場所には無い」移動だけを入れる。
    /// 結果の意味は `ApplyEngine.recoverJournal()` と同じ。`.recovered` の記録は `moves` が空で `sortMoves` だけを持つ
    /// （`SessionData.appendSorted` で同じ ID の適用の記録に足す）。
    public func recoverJournal() -> JournalRecovery {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path) else { return .none }
        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            return .unreadable("仕分けの記録を読めませんでした: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(SortJournal.self, from: data) else {
            let broken = FileSafety.brokenDestination(for: Self.journalFileName, in: folder)
            do {
                try fm.moveItem(at: journalURL, to: broken)
            } catch {
                return .unreadable("壊れた仕分けの記録を退避できませんでした: \(error.localizedDescription)")
            }
            return .broken(backup: broken)
        }
        var recovered: [MoveRecord] = []
        var seen = Set<String>()
        for mv in journal.moves + journal.pending {
            guard isValidMove(mv), isSubfolderInsideFolder(String(mv.to.split(separator: "/")[0])),
                  seen.insert(mv.from).inserted else { continue }
            let from = folder.appendingPathComponent(mv.from)
            let to = folder.appendingPathComponent(mv.to)
            if fm.fileExists(atPath: to.path), !FileSafety.exists(from) { recovered.append(mv) }
        }
        guard !recovered.isEmpty else {
            clearJournal()
            return .none
        }
        return .recovered(ApplyRecord(id: journal.id, date: journal.date, moves: [], sortMoves: recovered))
    }

    /// ジャーナルを削除する（記録を SessionData に保存した後に呼ぶ）
    public func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// 記録どおりフォルダ直下へ戻す。戻し先に既にファイルがある・失敗したものは飛ばして失敗一覧に入れる。
    /// 記録が「from = フォルダ直下の 1 要素、to = `JPG/` `RAW/` `Del/` 直下の 1 要素」の形でないもの、
    /// サブフォルダがシンボリックリンクでフォルダの外を指しているものは扱わない。
    /// 最後に空になった `JPG/` `RAW/` `Del/` を片付ける。
    func undo(_ moves: [MoveRecord]) -> MoveUndoResult {
        guard !moves.isEmpty else { return MoveUndoResult(restoredCount: 0, failures: [], remaining: []) }
        let fm = FileManager.default
        var failures: [ApplyFailure] = []
        var remaining: [MoveRecord] = []
        var restored = 0
        for mv in moves {
            guard isValidMove(mv), isSubfolderInsideFolder(String(mv.to.split(separator: "/")[0])) else {
                failures.append(ApplyFailure(path: mv.to, reason: "記録のパスが不正です"))
                remaining.append(mv)
                continue
            }
            let from = folder.appendingPathComponent(mv.from)
            let to = folder.appendingPathComponent(mv.to)
            if !fm.fileExists(atPath: to.path) {
                failures.append(ApplyFailure(path: mv.to, reason: "移動後のファイルが見つかりません"))
                remaining.append(mv)
            } else if FileSafety.exists(from) {
                failures.append(ApplyFailure(path: mv.to, reason: "戻し先に同じ名前のファイルがあります"))
                remaining.append(mv)
            } else {
                do {
                    try mover(to, from)
                    restored += 1
                } catch {
                    failures.append(ApplyFailure(path: mv.to, reason: error.localizedDescription))
                    remaining.append(mv)
                }
            }
        }
        removeEmptySubfolders()
        return MoveUndoResult(restoredCount: restored, failures: failures, remaining: remaining)
    }

    // MARK: - 内部

    /// 同じ名前（拡張子を除き、大文字小文字を無視）の JPG と RAW を 1 単位にまとめる（予定の順を保つ）。
    /// JPG と RAW のペアは別のフォルダへ移るが、片方だけが直下に残ると次に開いたとき RAW だけのコマに見え、
    /// もう一度仕分けると Del/ に入ってしまうため、適用と同じくそろって移す
    static func pairUnits(_ work: [MoveRecord]) -> [[MoveRecord]] {
        var order: [String] = []
        var byStem: [String: [MoveRecord]] = [:]
        for mv in work {
            // Del/ 行きは JPG が無いので 1 件で 1 単位
            let key = mv.to.hasPrefix(orphanFolderName + "/")
                ? "\0" + mv.from : (mv.from as NSString).deletingPathExtension.lowercased()
            if byStem[key] == nil { order.append(key) }
            byStem[key, default: []].append(mv)
        }
        return order.map { byStem[$0]! }
    }

    /// 1 単位を移す。どれかを移せなければ、先に移した分を直下へ戻して単位ごと失敗にする。
    /// 戻せなかったものは移ったままなので記録に入れ（取り消しで戻せる）、失敗一覧に明記する
    private func moveUnit(_ unit: [MoveRecord]) -> (moved: [MoveRecord], failures: [ApplyFailure]) {
        let fm = FileManager.default
        let pairNotMoved = "ペアのファイルを仕分けできなかったため、このファイルも移しませんでした"
        // 先にすべての元の存在と移動先の衝突を確認する
        var problems: [Int: String] = [:]
        for (k, mv) in unit.enumerated() {
            if !fm.fileExists(atPath: folder.appendingPathComponent(mv.from).path) {
                problems[k] = "元のファイルが見つかりません"
            } else if FileSafety.exists(folder.appendingPathComponent(mv.to)) {
                problems[k] = "移動先に同じ名前のファイルがあります"
            }
        }
        if !problems.isEmpty {
            return ([], unit.enumerated().map { ApplyFailure(path: $1.from, reason: problems[$0] ?? pairNotMoved) })
        }
        var done: [MoveRecord] = []
        for (k, mv) in unit.enumerated() {
            do {
                try mover(folder.appendingPathComponent(mv.from), folder.appendingPathComponent(mv.to))
                done.append(mv)
            } catch {
                var failures = [ApplyFailure(path: mv.from, reason: error.localizedDescription)]
                failures += unit[(k + 1)...].map { ApplyFailure(path: $0.from, reason: pairNotMoved) }
                var stuck: [MoveRecord] = []
                for moved in done {
                    do {
                        try mover(folder.appendingPathComponent(moved.to), folder.appendingPathComponent(moved.from))
                        failures.append(ApplyFailure(path: moved.from, reason: pairNotMoved))
                    } catch {
                        stuck.append(moved)
                        failures.append(ApplyFailure(
                            path: moved.from,
                            reason: "ペアのファイルを仕分けできなかったうえ、このファイルを元に戻せませんでした（\(moved.to) に移ったままです。取り消しで戻せます）: \(error.localizedDescription)"))
                    }
                }
                return (stuck, failures)
            }
        }
        return (done, [])
    }

    /// 仕分けの予定 1 件（移す前の名前と、入れるフォルダ）
    struct Planned: Equatable {
        let name: String
        let folder: String
    }

    /// 直下のファイルを仕分け先に割り当てる（名前順）。JPPhotoTools の 2 パス（先に孤立 RAW を Del/ へ、
    /// 次に残りを RAW/ JPG/ へ）と同じ結果になるよう、JPG の名前の集合は移す前のファイルから作る
    static func classify(_ files: [URL]) -> [Planned] {
        let stem = { (u: URL) in u.deletingPathExtension().lastPathComponent.lowercased() }
        let jpgStems = Set(files.filter { jpgExtensions.contains($0.pathExtension.lowercased()) }.map(stem))
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if jpgExtensions.contains(ext) { return Planned(name: name, folder: jpgFolderName) }
            guard rawExtensions.contains(ext) else { return nil }
            return Planned(name: name, folder: jpgStems.contains(stem(url)) ? rawFolderName : orphanFolderName)
        }
    }

    /// 直下の通常ファイル（ディレクトリ・シンボリックリンクを除く）。
    /// AppleDouble（`._` で始まる名前）は除く（JPPhotoTools との違い）。exFAT（SD カード）では macOS が本体の移動に
    /// 合わせて `._` のファイルも動かすので、別に移すと衝突したり、取り消しの記録が「見つからない」で残り続けたりする
    static func regularFiles(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { !$0.lastPathComponent.hasPrefix("._") }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// `sub` 直下で既存のファイルにも予定にもぶつからない名前（`name_1.ext`, `name_2.ext`, …）
    func uniqueName(for name: String, in sub: String, reserved: inout Set<String>) -> String {
        let dir = folder.appendingPathComponent(sub, isDirectory: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 1
        // 大文字小文字だけが違う名前は、大文字小文字を区別しないボリュームでぶつかるので同じとみなす
        while reserved.contains("\(sub)/\(candidate)".lowercased()) || FileSafety.exists(dir.appendingPathComponent(candidate)) {
            candidate = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            n += 1
        }
        reserved.insert("\(sub)/\(candidate)".lowercased())
        return candidate
    }

    private func writeJournal(_ journal: SortJournal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    /// 区切り・`.`・`..`・空を含まない 1 要素の名前か
    private static func isSingleComponent(_ s: Substring) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }

    /// 記録の形の検査: from はフォルダ直下の 1 要素、to は `JPG/` `RAW/` `Del/` のどれかの直下の 1 要素
    private func isValidMove(_ mv: MoveRecord) -> Bool {
        guard Self.isSingleComponent(Substring(mv.from)) else { return false }
        let parts = mv.to.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && Self.folderNames.contains(String(parts[0])) && Self.isSingleComponent(parts[1])
    }

    /// サブフォルダ自体がシンボリックリンクでフォルダの外を指していないか
    private func isSubfolderInsideFolder(_ name: String) -> Bool {
        let resolved = folder.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(name).path
        return resolved == expected
    }

    /// `JPG/` `RAW/` `Del/` のうち空（`.DS_Store` だけを含む）のものを削除する
    private func removeEmptySubfolders() {
        let fm = FileManager.default
        for name in Self.folderNames where isSubfolderInsideFolder(name) {
            let dir = folder.appendingPathComponent(name, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path),
                  names.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? fm.removeItem(at: dir)
        }
    }
}

/// 適用（と続けて行った仕分け）の結果
public struct ApplyOutcome: Sendable {
    public let apply: ApplyResult
    /// 仕分けの結果。仕分けしなかった（頼まれていない・しなかった）ときは nil
    public let sort: SortResult?
    /// 仕分けを頼まれたのにしなかった理由（ユーザーに見せてよい文）。仕分けした・頼まれていないときは nil
    public let sortSkippedReason: String?
    /// 仕分けの記録を足す適用の記録の ID と日時（適用で何も移さなかったときは仕分けだけの新しい記録になる）
    let sortRecordID: UUID
    let sortDate: Date

    /// 仕分けの移動を、`SessionData.appendSorted` に渡す形にしたもの。仕分けで何も移さなかったときは nil
    public var sortRecord: ApplyRecord? {
        guard let sort, !sort.moves.isEmpty else { return nil }
        return ApplyRecord(id: sortRecordID, date: sortDate, moves: [], sortMoves: sort.moves)
    }
}

extension FolderSorter {
    /// `_rejected` へ移し、`sort` なら続けて残った写真を仕分ける。
    /// - 仕分けのジャーナルが残っている（前回の仕分けを取り込めていない）ときは、移動もしない（移動だけされて仕分けが全件失敗する、
    ///   中途半端な状態にしないため）
    /// - 適用で 1 件でも失敗したときは仕分けしない（直下に残った不採用の写真が JPG/ RAW/ に混ざるため）
    /// 同期 API。UI からはバックグラウンドで呼ぶこと。
    public static func applyAndSort(_ plan: ApplyPlan, sort: Bool, engine: ApplyEngine, sorter: FolderSorter) -> ApplyOutcome {
        if sort, FileManager.default.fileExists(atPath: sorter.journalURL.path) {
            return ApplyOutcome(
                apply: ApplyResult(record: nil, failures: [], movedJPGCount: 0, movedRAWCount: 0), sort: nil,
                sortSkippedReason: "前回の仕分けの記録が残っているため、移動も仕分けもしませんでした。フォルダを開き直して記録を取り込んでください。",
                sortRecordID: UUID(), sortDate: Date())
        }
        let result = engine.apply(plan)
        let id = result.record?.id ?? UUID()
        let date = result.record?.date ?? Date()
        guard sort else {
            return ApplyOutcome(apply: result, sort: nil, sortSkippedReason: nil, sortRecordID: id, sortDate: date)
        }
        guard result.failures.isEmpty else {
            return ApplyOutcome(
                apply: result, sort: nil,
                sortSkippedReason: "移動できなかったファイルがあるため、仕分けはしませんでした（移せなかった不採用の写真が JPG・RAW フォルダに混ざるのを防ぐため）。",
                sortRecordID: id, sortDate: date)
        }
        return ApplyOutcome(apply: result, sort: sorter.sort(id: id, date: date), sortSkippedReason: nil,
                            sortRecordID: id, sortDate: date)
    }
}

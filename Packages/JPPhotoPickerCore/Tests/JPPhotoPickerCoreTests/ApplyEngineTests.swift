import Testing
import Foundation
@testable import JPPhotoPickerCore

private func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("JPPhotoPickerApply-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func touch(_ dir: URL, _ names: [String]) {
    for n in names { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([1])) }
}

private func has(_ dir: URL, _ rel: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path)
}

/// フォルダを走査して、指定コマ ID を採用していない（不採用）、それ以外を採用にした状態の予定を作る
private func plan(_ dir: URL, rejecting ids: [String]) throws -> ApplyPlan {
    let items = try FolderScanner.scan(folder: dir)
    let groups = BurstGrouper.group(items)
    let rejected = Set(ids)
    return ApplyEngine.plan(groups: groups, decisions: Dictionary(uniqueKeysWithValues: items.map {
        ($0.id, rejected.contains($0.id) ? Decision.undecided : .picked)
    }))
}

@Suite("ApplyEngine")
struct ApplyEngineTests {
    @Test("予定の枚数（JPG・ARW）とファイル一覧")
    func planCounts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG", "A1_0003.ARW", "A1_0004.JPG", "A1_0004.arw"])
        let p = try plan(dir, rejecting: ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.ARW"])
        #expect(p.jpgCount == 2)
        #expect(p.arwCount == 2)
        #expect(p.files.count == 4)
        #expect(!p.isEmpty)
        #expect(try plan(dir, rejecting: []).isEmpty)
    }

    @Test("JPG と ARW（大文字小文字違いの拡張子も）を一緒に _rejected へ移し、記録を返す")
    func applyMoves() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.arw", "A1_0002.JPG", "A1_0002.ARW", "A1_0003.ARW"])
        let p = try plan(dir, rejecting: ["A1_0001.JPG", "A1_0003.ARW"])
        let r = ApplyEngine(folder: dir).apply(p)
        #expect(r.failures.isEmpty)
        #expect(r.movedJPGCount == 1)
        #expect(r.movedARWCount == 2)
        #expect(has(dir, "_rejected/A1_0001.JPG"))
        #expect(has(dir, "_rejected/A1_0001.arw"))
        #expect(has(dir, "_rejected/A1_0003.ARW"))
        #expect(!has(dir, "A1_0001.JPG") && !has(dir, "A1_0003.ARW"))
        #expect(has(dir, "A1_0002.JPG") && has(dir, "A1_0002.ARW"))
        let rec = try #require(r.record)
        #expect(Set(rec.moves.map(\.from)) == ["A1_0001.JPG", "A1_0001.arw", "A1_0003.ARW"])
        #expect(rec.moves.allSatisfy { $0.to == "_rejected/" + $0.from })
    }

    @Test("ARW だけのコマを不採用にすると ARW だけが移る")
    func arwOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.ARW", "A1_0002.JPG"])
        let r = ApplyEngine(folder: dir).apply(try plan(dir, rejecting: ["A1_0001.ARW"]))
        #expect(r.movedJPGCount == 0 && r.movedARWCount == 1)
        #expect(has(dir, "_rejected/A1_0001.ARW") && has(dir, "A1_0002.JPG"))
    }

    @Test("移動先に同名があるファイルは飛ばして失敗に入れ、上書きしない。ペアのもう片方も移さない")
    func collision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW"])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_rejected"), withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: dir.appendingPathComponent("_rejected/A1_0001.JPG"))
        let r = ApplyEngine(folder: dir).apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        #expect(Set(r.failures.map(\.path)) == ["A1_0001.JPG", "A1_0001.ARW"])
        #expect(r.failures.first { $0.path == "A1_0001.ARW" }?.reason == "ペアの JPG を移せなかったため ARW も移しませんでした")
        #expect(r.movedARWCount == 0 && r.movedJPGCount == 0 && r.record == nil)
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0001.ARW") && !has(dir, "_rejected/A1_0001.ARW"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("_rejected/A1_0001.JPG")) == Data([9, 9, 9]))
    }

    @Test("ARW 側の移動先に同名があると、JPG も移さず残る")
    func arwCollisionKeepsJPG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG"])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_rejected"), withIntermediateDirectories: true)
        try Data([9]).write(to: dir.appendingPathComponent("_rejected/A1_0001.ARW"))
        let r = ApplyEngine(folder: dir).apply(try plan(dir, rejecting: ["A1_0001.JPG", "A1_0002.JPG"]))
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0001.ARW") && !has(dir, "_rejected/A1_0001.JPG"))
        #expect(r.failures.first { $0.path == "A1_0001.JPG" }?.reason == "ペアの ARW を移せなかったため JPG も移しませんでした")
        #expect(r.record?.moves.map(\.from) == ["A1_0002.JPG"])
    }

    @Test("ペアの ARW が消えていたら JPG も移さない")
    func arwMissingKeepsJPG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW"])
        let p = try plan(dir, rejecting: ["A1_0001.JPG"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("A1_0001.ARW"))
        let r = ApplyEngine(folder: dir).apply(p)
        #expect(r.record == nil && has(dir, "A1_0001.JPG") && !has(dir, "_rejected"))
        #expect(r.failures.count == 2)
    }

    @Test("2 つ目の移動が失敗したら 1 つ目を元に戻し、ペアごと失敗にする")
    func secondMoveFailsRollsBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG", "A1_0002.ARW"])
        struct Boom: Error, LocalizedError { var errorDescription: String? { "失敗" } }
        var engine = ApplyEngine(folder: dir)
        engine.mover = { from, to in
            if from.lastPathComponent == "A1_0001.ARW" { throw Boom() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG", "A1_0002.JPG"]))
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0001.ARW") && !has(dir, "_rejected/A1_0001.JPG"))
        #expect(has(dir, "_rejected/A1_0002.JPG") && has(dir, "_rejected/A1_0002.ARW"))
        #expect(r.failures.first { $0.path == "A1_0001.JPG" }?.reason == "ペアの ARW を移せなかったため JPG も移しませんでした")
        #expect(r.failures.first { $0.path == "A1_0001.ARW" }?.reason == "失敗")
        #expect(r.movedJPGCount == 1 && r.movedARWCount == 1)
        #expect(Set(r.record?.moves.map(\.from) ?? []) == ["A1_0002.JPG", "A1_0002.ARW"])
    }

    @Test("JPG 側の移動が失敗したら ARW も移さない")
    func firstMoveFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW"])
        struct Boom: Error {}
        var engine = ApplyEngine(folder: dir)
        engine.mover = { _, _ in throw Boom() }
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        #expect(r.record == nil && has(dir, "A1_0001.JPG") && has(dir, "A1_0001.ARW"))
        #expect(r.failures.first { $0.path == "A1_0001.ARW" }?.reason == "ペアの JPG を移せなかったため ARW も移しませんでした")
        #expect(!has(dir, "_rejected"))
    }

    @Test("戻すのにも失敗したら、移ったままの方を記録に残して失敗一覧に明記し、取り消せる")
    func rollbackFailureIsRecorded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW"])
        struct Boom: Error {}
        var engine = ApplyEngine(folder: dir)
        engine.mover = { from, to in
            if from.lastPathComponent == "A1_0001.ARW" || from.deletingLastPathComponent().lastPathComponent == "_rejected" { throw Boom() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        #expect(!has(dir, "A1_0001.JPG") && has(dir, "_rejected/A1_0001.JPG") && has(dir, "A1_0001.ARW"))
        #expect(r.record?.moves.map(\.from) == ["A1_0001.JPG"])
        #expect(r.movedJPGCount == 1 && r.movedARWCount == 0)
        #expect(r.failures.first { $0.path == "A1_0001.JPG" }?.reason.contains("元に戻せませんでした") == true)
        // ジャーナルも記録と一致し、取り消しで戻せる
        guard case .recovered(let rec) = ApplyEngine(folder: dir).recoverJournal() else { Issue.record("recovered ではない"); return }
        #expect(rec.moves.map(\.from) == ["A1_0001.JPG"])
        let u = ApplyEngine(folder: dir).undo(try #require(r.record))
        #expect(u.restoredCount == 1 && has(dir, "A1_0001.JPG"))
    }

    @Test("元ファイルが消えていたら失敗に入れる。全部失敗なら記録は nil で空の _rejected は残さない")
    func missingSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG"])
        let p = try plan(dir, rejecting: ["A1_0001.JPG"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("A1_0001.JPG"))
        let r = ApplyEngine(folder: dir).apply(p)
        #expect(r.record == nil)
        #expect(r.failures.count == 1)
        #expect(!has(dir, "_rejected"))
    }

    @Test("取り消しで元に戻り、空になった _rejected は消える。SessionData から記録を外せる")
    func undo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG"])
        let engine = ApplyEngine(folder: dir)
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        var session = SessionData()
        session.appendApplied(try #require(r.record))
        #expect(session.applied.count == 1)
        #expect(has(dir, "_rejected/.jpphotopicker-apply-journal.json"))   // 適用後もジャーナルは残る
        engine.clearJournal()

        let rec = session.applied[0]
        let u = engine.undo(rec)
        #expect(u.failures.isEmpty && u.restoredCount == 2 && u.remainingRecord == nil)
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0001.ARW"))
        #expect(!has(dir, "_rejected"))
        let appended = session.finishUndo(of: rec, result: u)
        #expect(appended)
        #expect(session.applied.isEmpty)
        // 見つからない記録は false
        let notFound = session.finishUndo(of: rec, result: u)
        #expect(!notFound)
    }

    @Test("戻し先に同名があれば飛ばし、戻せなかった分だけ記録に残す。_rejected は残る")
    func undoCollision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW"])
        let engine = ApplyEngine(folder: dir)
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        let rec = try #require(r.record)
        try Data([7]).write(to: dir.appendingPathComponent("A1_0001.JPG"))   // 同名の別ファイル

        let u = engine.undo(rec)
        #expect(u.restoredCount == 1)
        #expect(u.failures.map(\.path) == ["_rejected/A1_0001.JPG"])
        #expect(u.remainingRecord?.moves.map(\.from) == ["A1_0001.JPG"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("A1_0001.JPG")) == Data([7]))
        #expect(has(dir, "_rejected/A1_0001.JPG"))

        var session = SessionData(applied: [rec])
        session.finishUndo(of: rec, result: u)
        #expect(session.applied.count == 1)
        #expect(session.applied[0].moves.count == 1)
    }

    @Test("記録のパスがフォルダ外を指していたら触らない")
    func undoRejectsEscapingPaths() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = ApplyRecord(date: Date(), moves: [MoveRecord(from: "../evil.JPG", to: "_rejected/x.JPG"),
                                                   MoveRecord(from: "/abs.JPG", to: "_rejected/y.JPG")])
        let u = ApplyEngine(folder: dir).undo(rec)
        #expect(u.restoredCount == 0 && u.failures.count == 2 && u.remainingRecord?.moves.count == 2)
    }

    // MARK: - M6: 記録の id

    @Test("ApplyRecord: 古い JSON（id なし）は読み込み時に id を作る。id は往復で保たれる")
    func recordID() throws {
        let json = #"{"date":"2026-09-29T00:00:00Z","moves":[{"from":"a.JPG","to":"_rejected/a.JPG"}]}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(ApplyRecord.self, from: Data(json.utf8))
        #expect(r.moves.count == 1)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let r2 = try dec.decode(ApplyRecord.self, from: try enc.encode(r))
        #expect(r2.id == r.id)
    }

    @Test("finishUndo は id で探す（同じ内容の記録が複数あっても取り違えない）")
    func finishUndoByID() {
        let mv = [MoveRecord(from: "a.JPG", to: "_rejected/a.JPG")]
        let r1 = ApplyRecord(date: Date(timeIntervalSince1970: 1), moves: mv)
        let r2 = ApplyRecord(date: Date(timeIntervalSince1970: 1), moves: mv)
        var s = SessionData(applied: [r1, r2])
        let done = UndoResult(restoredCount: 1, failures: [], remainingRecord: nil)
        let appended = s.finishUndo(of: r2, result: done)
        #expect(appended)
        #expect(s.applied == [r1])
        // 一部だけ戻せたときは id を保ったまま置き換える
        let part = UndoResult(restoredCount: 0, failures: [], remainingRecord: ApplyRecord(id: r1.id, date: r1.date, moves: mv))
        let partial = s.finishUndo(of: r1, result: part)
        #expect(partial)
        #expect(s.applied.count == 1 && s.applied[0].id == r1.id)
    }

    // MARK: - M4: ジャーナル

    @Test("適用のジャーナル: 完了後の内容が record と一致し、recover → 取り込み → clear で消える")
    func journalAfterApply() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // バッチ境界（32）をまたぐ件数
        let names = (1...70).map { String(format: "A1_%04d.JPG", $0) }
        touch(dir, names)
        let engine = ApplyEngine(folder: dir)
        let r = engine.apply(try plan(dir, rejecting: names))
        let rec = try #require(r.record)
        #expect(rec.moves.count == 70)
        guard case .recovered(let recovered) = engine.recoverJournal() else { Issue.record("recovered ではない"); return }
        #expect(recovered.id == rec.id)
        #expect(Set(recovered.moves) == Set(rec.moves))
        // 取り込みは二重にならない
        var session = SessionData()
        let appended = session.appendApplied(rec)
        #expect(appended)
        let dup = session.appendApplied(recovered)
        #expect(!dup)
        engine.clearJournal()
        #expect(!has(dir, "_rejected/.jpphotopicker-apply-journal.json"))
        #expect(engine.recoverJournal() == .none)
        #expect(has(dir, "_rejected/A1_0001.JPG"))
    }

    @Test("途中で止まった適用: ジャーナルから、移動済み（確認済み・予定分とも）だけを復旧する")
    func journalRecoveryAfterCrash() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.JPG", "A1_0004.JPG", "A1_0005.JPG"])
        let rej = dir.appendingPathComponent("_rejected")
        try FileManager.default.createDirectory(at: rej, withIntermediateDirectories: true)
        // 1, 2 は確認済みの移動。3 は予定に入っていて実際に移動済み。4 は予定だけで未移動。5 は無関係
        for n in ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.JPG"] {
            try FileManager.default.moveItem(at: dir.appendingPathComponent(n), to: rej.appendingPathComponent(n))
        }
        func mv(_ n: String) -> MoveRecord { MoveRecord(from: n, to: "_rejected/\(n)") }
        let id = UUID()
        let journal = ApplyJournal(id: id, date: Date(timeIntervalSince1970: 1_790_000_000),
                                   moves: [mv("A1_0001.JPG"), mv("A1_0002.JPG")],
                                   pending: [mv("A1_0003.JPG"), mv("A1_0004.JPG")])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(journal).write(to: rej.appendingPathComponent(".jpphotopicker-apply-journal.json"))

        let engine = ApplyEngine(folder: dir)
        guard case .recovered(let rec) = engine.recoverJournal() else { Issue.record("recovered ではない"); return }
        #expect(rec.id == id)
        #expect(rec.moves.map(\.from) == ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.JPG"])

        // 復旧した記録で取り消せる
        var session = SessionData()
        session.appendApplied(rec)
        engine.clearJournal()
        let u = engine.undo(session.applied[0])
        #expect(u.restoredCount == 3 && u.remainingRecord == nil)
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0003.JPG") && has(dir, "A1_0004.JPG"))
        #expect(!has(dir, "_rejected"))
    }

    @Test("壊れたジャーナルは .broken で退避（_rejected の外）、次の適用を妨げず、_rejected の空判定も妨げない")
    func journalEmptyOrBroken() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rej = dir.appendingPathComponent("_rejected")
        try FileManager.default.createDirectory(at: rej, withIntermediateDirectories: true)
        let jurl = rej.appendingPathComponent(".jpphotopicker-apply-journal.json")
        try Data("not json".utf8).write(to: jurl)
        let engine = ApplyEngine(folder: dir)
        guard case .broken(let backup) = engine.recoverJournal() else { Issue.record("broken ではない"); return }
        #expect(!FileManager.default.fileExists(atPath: jurl.path))
        // 退避先はフォルダ直下（_rejected の中ではない）で、中身は元のまま
        #expect(backup.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(backup.lastPathComponent.hasPrefix(".jpphotopicker-apply-journal.json.broken"))
        #expect(try Data(contentsOf: backup) == Data("not json".utf8))
        // 空になった _rejected は片付く
        #expect(!has(dir, "_rejected"))

        touch(dir, ["A1_0001.JPG"])
        let r = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))
        #expect(r.record != nil && r.failures.isEmpty)
        // 退避ファイルは残っている
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("復旧できる移動が無いジャーナルは .none でジャーナルを片付ける")
    func journalWithNothingToRecover() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rej = dir.appendingPathComponent("_rejected")
        try FileManager.default.createDirectory(at: rej, withIntermediateDirectories: true)
        let journal = ApplyJournal(id: UUID(), date: Date(), moves: [],
                                   pending: [MoveRecord(from: "A1_0001.JPG", to: "_rejected/A1_0001.JPG")])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(journal).write(to: rej.appendingPathComponent(".jpphotopicker-apply-journal.json"))
        let engine = ApplyEngine(folder: dir)
        #expect(engine.recoverJournal() == .none)
        #expect(!has(dir, "_rejected"))
        #expect(engine.recoverJournal() == .none)
    }

    @Test("_rejected がフォルダ外へのシンボリックリンクのとき、ジャーナルは .unreadable")
    func journalUnreadableWhenRejectedEscapes() throws {
        let dir = try makeTempDir()
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try Data("x".utf8).write(to: outside.appendingPathComponent(".jpphotopicker-apply-journal.json"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("_rejected"), withDestinationURL: outside)
        guard case .unreadable = ApplyEngine(folder: dir).recoverJournal() else { Issue.record("unreadable ではない"); return }
    }

    // MARK: - C4: _rejected が無い undo

    @Test("undo: _rejected が無いときは「移動後のファイルが見つかりません」")
    func undoWithoutRejectedFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = ApplyRecord(date: Date(), moves: [MoveRecord(from: "a.JPG", to: "_rejected/a.JPG")])
        let u = ApplyEngine(folder: dir).undo(rec)
        #expect(u.restoredCount == 0)
        #expect(u.failures == [ApplyFailure(path: "_rejected/a.JPG", reason: "移動後のファイルが見つかりません")])
        #expect(u.remainingRecord?.moves == rec.moves)
    }

    // MARK: - symlink を含むフォルダ URL

    @Test("/tmp（/private/tmp への symlink）経由のフォルダ URL で apply → undo が往復できる")
    func applyUndoThroughSymlinkedFolder() throws {
        let real = URL(fileURLWithPath: "/private/tmp/JPPhotoPickerSymlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let viaSymlink = URL(fileURLWithPath: "/tmp/" + real.lastPathComponent, isDirectory: true)
        touch(real, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG"])
        let engine = ApplyEngine(folder: viaSymlink)
        let p = try plan(viaSymlink, rejecting: ["A1_0001.JPG"])
        let r = engine.apply(p)
        #expect(r.failures.isEmpty)
        let rec = try #require(r.record)
        #expect(rec.moves.count == 2)
        #expect(has(real, "_rejected/A1_0001.JPG") && has(real, "_rejected/A1_0001.ARW"))
        #expect(!has(real, "A1_0001.JPG"))
        // ジャーナルも復旧できる
        guard case .recovered(let again) = engine.recoverJournal() else { Issue.record("recovered ではない"); return }
        #expect(again.id == rec.id)
        engine.clearJournal()
        let u = engine.undo(rec)
        #expect(u.failures.isEmpty && u.restoredCount == 2 && u.remainingRecord == nil)
        #expect(has(real, "A1_0001.JPG") && has(real, "A1_0001.ARW") && !has(real, "_rejected"))
    }

    // MARK: - ジャーナル書き込み失敗

    @Test("ジャーナルを書けないとき（journalFailed）は何も移さず全件失敗にし、_rejected を残さない")
    func applyStopsWhenJournalCannotBeWritten() throws {
        let dir = try makeTempDir()
        let rej = dir.appendingPathComponent("_rejected")
        try FileManager.default.createDirectory(at: rej, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rej.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rej.path)
            try? FileManager.default.removeItem(at: dir)
        }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.ARW"])
        let r = ApplyEngine(folder: dir).apply(try plan(dir, rejecting: ["A1_0001.JPG", "A1_0002.JPG", "A1_0003.ARW"]))
        #expect(r.record == nil)
        #expect(r.failures.count == 3)
        #expect(r.failures.allSatisfy { $0.reason.contains("適用の記録を書けなかった") })
        #expect(has(dir, "A1_0001.JPG") && has(dir, "A1_0002.JPG") && has(dir, "A1_0003.ARW"))
        #expect(!has(dir, "_rejected"))
    }

    @Test("ジャーナルが残っている間の適用は何も移さず失敗にする")
    func applyRefusesWithStaleJournal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG"])
        let engine = ApplyEngine(folder: dir)
        _ = engine.apply(try plan(dir, rejecting: ["A1_0001.JPG"]))   // ジャーナルが残る
        let r = engine.apply(try plan(dir, rejecting: ["A1_0002.JPG"]))
        #expect(r.record == nil && r.failures.count == 1)
        #expect(has(dir, "A1_0002.JPG"))
    }

    // MARK: - L10/L11: パスの検査

    @Test("undo: from が入れ子、to が _rejected 直下の 1 要素でない記録は扱わない")
    func undoRejectsBadShapes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("_rejected/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("other"), withIntermediateDirectories: true)
        touch(dir, ["_rejected/sub/a.JPG", "_rejected/b.JPG", "_rejected/c.JPG"].map { $0 })
        let rec = ApplyRecord(date: Date(), moves: [
            MoveRecord(from: "other/x.JPG", to: "_rejected/b.JPG"),       // from が入れ子
            MoveRecord(from: "a.JPG", to: "_rejected/sub/a.JPG"),         // to が入れ子
            MoveRecord(from: "c.JPG", to: "other/c.JPG"),                 // to が _rejected でない
            MoveRecord(from: "./d.JPG", to: "_rejected/c.JPG"),           // "." を含む
        ])
        let u = ApplyEngine(folder: dir).undo(rec)
        #expect(u.restoredCount == 0 && u.failures.count == 4 && u.remainingRecord?.moves.count == 4)
        #expect(has(dir, "_rejected/b.JPG") && has(dir, "_rejected/c.JPG") && has(dir, "_rejected/sub/a.JPG"))
    }

    @Test("undo: _rejected がフォルダ外へのシンボリックリンクなら触らない")
    func undoRejectsSymlinkedRejected() throws {
        let dir = try makeTempDir()
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        touch(outside, ["a.JPG"])
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("_rejected"), withDestinationURL: outside)
        let rec = ApplyRecord(date: Date(), moves: [MoveRecord(from: "a.JPG", to: "_rejected/a.JPG")])
        let u = ApplyEngine(folder: dir).undo(rec)
        #expect(u.restoredCount == 0 && u.failures.count == 1)
        #expect(has(outside, "a.JPG") && !has(dir, "a.JPG"))
    }

    @Test("apply: plan の URL がフォルダ直下でなければ失敗にする")
    func applyRejectsOutsideURLs() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        touch(dir, ["A1_0001.JPG"])
        touch(other, ["evil.JPG"])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        touch(dir, ["sub/deep.JPG"])
        let p = ApplyPlan(candidates: [
            MoveCandidate(id: "evil.JPG", jpgURL: other.appendingPathComponent("evil.JPG"), arwURL: nil),
            MoveCandidate(id: "deep.JPG", jpgURL: dir.appendingPathComponent("sub/deep.JPG"), arwURL: nil),
            MoveCandidate(id: "A1_0001.JPG", jpgURL: dir.appendingPathComponent("A1_0001.JPG"), arwURL: nil),
        ])
        let r = ApplyEngine(folder: dir).apply(p)
        #expect(r.failures.map(\.path) == ["evil.JPG", "deep.JPG"])
        #expect(r.record?.moves.map(\.from) == ["A1_0001.JPG"])
        #expect(has(other, "evil.JPG") && has(dir, "sub/deep.JPG"))
    }

    @Test("undo: 2 件中 1 件の移動が失敗したら、戻せた分だけ数え、失敗した分を記録に残す")
    func undoPartialMoverFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG"])
        var engine = ApplyEngine(folder: dir)
        let rec = try #require(engine.apply(try plan(dir, rejecting: ["A1_0001.JPG", "A1_0002.JPG"])).record)
        engine.clearJournal()
        #expect(rec.moves.count == 2)

        // 取り消しも差し替えた mover を通る: A1_0002 の戻しだけ失敗させる
        struct Boom: Error, LocalizedError { var errorDescription: String? { "戻せない" } }
        engine.mover = { from, to in
            if from.lastPathComponent == "A1_0002.JPG" { throw Boom() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let u = engine.undo(rec)
        #expect(u.restoredCount == 1)
        #expect(u.failures == [ApplyFailure(path: "_rejected/A1_0002.JPG", reason: "戻せない")])
        #expect(u.remainingRecord?.id == rec.id)
        #expect(u.remainingRecord?.moves.map(\.from) == ["A1_0002.JPG"])
        #expect(has(dir, "A1_0001.JPG") && !has(dir, "_rejected/A1_0001.JPG"))
        #expect(has(dir, "_rejected/A1_0002.JPG") && !has(dir, "A1_0002.JPG"))   // _rejected は残る
    }
}

// MARK: - 退避先の命名・存在確認

@Suite("FileSafety")
struct FileSafetyTests {
    @Test("退避先は <名前>.broken-yyyyMMdd-HHmmss、既にあれば -2、-3 と連番。壊れたリンクも「ある」とみなす")
    func brokenDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = FileSafety.brokenDestination(for: ".x.json", in: dir, date: date)
        let stamp = first.lastPathComponent.dropFirst(".x.json.broken-".count)
        #expect(first.lastPathComponent.hasPrefix(".x.json.broken-"))
        #expect(stamp.count == 15 && stamp.dropFirst(8).first == "-")   // yyyyMMdd-HHmmss
        #expect(first.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)

        // 1 つ目の名前に壊れたシンボリックリンクを置く → 存在扱いで -2
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        #expect(!FileManager.default.fileExists(atPath: first.path))   // fileExists はリンク先を見るので false
        #expect(FileSafety.exists(first))
        let second = FileSafety.brokenDestination(for: ".x.json", in: dir, date: date)
        #expect(second.lastPathComponent == first.lastPathComponent + "-2")
        try Data([1]).write(to: second)
        let third = FileSafety.brokenDestination(for: ".x.json", in: dir, date: date)
        #expect(third.lastPathComponent == first.lastPathComponent + "-3")
    }
}

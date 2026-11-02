import Testing
import Foundation
@testable import JPPhotoPickerCore

private func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("JPPhotoPickerSort-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func touch(_ dir: URL, _ names: [String]) {
    for n in names { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([1])) }
}

private func has(_ dir: URL, _ rel: String) -> Bool {
    FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path)
}

private struct MoveFailed: Error, LocalizedError {
    var errorDescription: String? { "わざと失敗" }
}

@Suite("FolderSorter")
struct FolderSorterTests {
    @Test("JPPhotoTools の仕分けと同じ: JPG は JPG/、ペアの RAW は RAW/、JPG の無い RAW は Del/、それ以外は動かさない")
    func sortsLikeRawTrash() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG", "A.ARW", "B.JPG", "C.ORF", "D.dng", "d.jpeg", "E.CR3", "note.txt", ".jpphotopicker.json"])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_rejected"), withIntermediateDirectories: true)
        touch(dir.appendingPathComponent("_rejected"), ["X.JPG"])

        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.failures.isEmpty)
        #expect(r.jpgCount == 3 && r.rawCount == 2 && r.orphanCount == 2)
        for p in ["JPG/A.JPG", "JPG/B.JPG", "JPG/d.jpeg", "RAW/A.ARW", "RAW/D.dng", "Del/C.ORF", "Del/E.CR3"] {
            #expect(has(dir, p), "\(p)")
        }
        // 対象外のファイルとサブフォルダの中身は動かさない
        #expect(has(dir, "note.txt") && has(dir, ".jpphotopicker.json") && has(dir, "_rejected/X.JPG"))
        #expect(Set(r.moves.map(\.from)) == ["A.JPG", "A.ARW", "B.JPG", "C.ORF", "D.dng", "d.jpeg", "E.CR3"])
    }

    @Test("JPG/ RAW/ Del/ は空でも作る")
    func createsAllFolders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG"])
        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.moves == [MoveRecord(from: "A.JPG", to: "JPG/A.JPG")])
        #expect(has(dir, "RAW") && has(dir, "Del"))
    }

    @Test("移動先に同じ名前があれば番号を付け、記録にはその名前を残す")
    func numbersOnCollision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("JPG")
        try FileManager.default.createDirectory(at: jpg, withIntermediateDirectories: true)
        touch(jpg, ["A.JPG", "A_1.JPG"])
        touch(dir, ["A.JPG"])
        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.moves == [MoveRecord(from: "A.JPG", to: "JPG/A_2.JPG")])
        #expect(has(dir, "JPG/A_2.JPG"))
    }

    @Test("移せなかったファイルは飛ばして失敗一覧に入れ、残りは移す")
    func continuesAfterFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG", "B.JPG"])
        var sorter = FolderSorter(folder: dir)
        sorter.mover = { from, to in
            if from.lastPathComponent == "A.JPG" { throw MoveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let r = sorter.sort(id: UUID(), date: Date())
        #expect(r.moves.map(\.from) == ["B.JPG"])
        #expect(r.failures == [ApplyFailure(path: "A.JPG", reason: "わざと失敗")])
        #expect(has(dir, "A.JPG") && has(dir, "JPG/B.JPG"))
    }

    @Test("ペアの片方を移せなければ、もう片方も直下に戻してペアごと失敗にする")
    func pairMovesTogether() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.ARW", "A.JPG", "B.JPG"])
        var sorter = FolderSorter(folder: dir)
        sorter.mover = { from, to in
            if from.lastPathComponent == "A.JPG" { throw MoveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let r = sorter.sort(id: UUID(), date: Date())
        #expect(r.moves == [MoveRecord(from: "B.JPG", to: "JPG/B.JPG")])
        #expect(Set(r.failures.map(\.path)) == ["A.ARW", "A.JPG"])
        #expect(has(dir, "A.ARW") && has(dir, "A.JPG") && !has(dir, "RAW/A.ARW"))
    }

    @Test("AppleDouble（._ で始まるファイル）は動かさない")
    func skipsAppleDouble() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG", "._A.JPG", "._A.ARW"])
        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.moves == [MoveRecord(from: "A.JPG", to: "JPG/A.JPG")])
        #expect(has(dir, "._A.JPG") && has(dir, "._A.ARW"))
    }

    @Test("大文字小文字だけが違う名前は、移動先で同じ名前とみなして番号を付ける")
    func caseInsensitiveReservation() {
        var reserved = Set<String>()
        let sorter = FolderSorter(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let a = sorter.uniqueName(for: "a.jpg", in: "JPG", reserved: &reserved)
        let b = sorter.uniqueName(for: "A.JPG", in: "JPG", reserved: &reserved)
        #expect(a == "a.jpg" && b == "A_1.JPG")
    }

    @Test("サブフォルダがフォルダの外を指すシンボリックリンクなら、仕分けを中止し、取り消しでも扱わない")
    func refusesSymlinkedSubfolder() throws {
        let dir = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("RAW"), withDestinationURL: outside)
        touch(dir, ["A.JPG", "A.ARW"])
        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.moves.isEmpty && r.failures.count == 2)
        #expect(has(dir, "A.JPG") && has(dir, "A.ARW") && !has(dir, "JPG"))

        touch(outside, ["B.ARW"])
        let u = ApplyEngine(folder: dir).undo(ApplyRecord(date: Date(), moves: [], sortMoves: [MoveRecord(from: "B.ARW", to: "RAW/B.ARW")]))
        #expect(u.restoredCount == 0 && u.failures.first?.reason == "記録のパスが不正です")
        #expect(!has(dir, "B.ARW"))
    }

    @Test("applyAndSort: 移動に続けて仕分け、記録は同じ ID にまとまる")
    func applyAndSortSucceeds() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG", "A1_0002.ARW"])
        let items = try FolderScanner.scan(folder: dir)
        let plan = ApplyEngine.plan(groups: BurstGrouper.group(items), decisions: ["A1_0002.JPG": .picked])
        let o = FolderSorter.applyAndSort(plan, sort: true, engine: ApplyEngine(folder: dir), sorter: FolderSorter(folder: dir))
        #expect(o.sortSkippedReason == nil)
        let rec = try #require(o.apply.record)
        #expect(o.sortRecord?.id == rec.id)
        #expect(has(dir, "_rejected/A1_0001.JPG") && has(dir, "JPG/A1_0002.JPG") && has(dir, "RAW/A1_0002.ARW"))
    }

    @Test("applyAndSort: 適用で失敗があれば仕分けしない")
    func applyAndSortSkipsAfterFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0002.JPG"])
        let items = try FolderScanner.scan(folder: dir)
        let plan = ApplyEngine.plan(groups: BurstGrouper.group(items), decisions: [:])
        var engine = ApplyEngine(folder: dir)
        engine.mover = { from, to in
            if from.lastPathComponent == "A1_0001.JPG" { throw MoveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let o = FolderSorter.applyAndSort(plan, sort: true, engine: engine, sorter: FolderSorter(folder: dir))
        #expect(o.sort == nil && o.sortSkippedReason != nil && o.sortRecord == nil)
        #expect(has(dir, "A1_0001.JPG") && !has(dir, "JPG"))
    }

    @Test("applyAndSort: 仕分けのジャーナルが残っていたら移動もしない。仕分けを頼まなければ移動する")
    func applyAndSortRefusesWithLeftoverJournal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", FolderSorter.journalFileName])
        let items = try FolderScanner.scan(folder: dir)
        let plan = ApplyEngine.plan(groups: BurstGrouper.group(items), decisions: [:])
        let refused = FolderSorter.applyAndSort(plan, sort: true, engine: ApplyEngine(folder: dir), sorter: FolderSorter(folder: dir))
        #expect(refused.apply.record == nil && refused.sortSkippedReason != nil)
        #expect(has(dir, "A1_0001.JPG"))
        let plain = FolderSorter.applyAndSort(plan, sort: false, engine: ApplyEngine(folder: dir), sorter: FolderSorter(folder: dir))
        #expect(plain.apply.record != nil && plain.sortSkippedReason == nil)
    }

    @Test("前回の仕分けのジャーナルが残っていたら何も移さない")
    func refusesWithLeftoverJournal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG", FolderSorter.journalFileName])
        let r = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        #expect(r.moves.isEmpty && r.failures.count == 1)
        #expect(has(dir, "A.JPG"))
    }

    @Test("適用＋仕分けの記録を取り消すと、_rejected と JPG/ RAW/ Del/ の写真がすべて直下に戻り、空のフォルダは消える")
    func undoRestoresEverything() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG", "A1_0002.ARW", "A1_0003.ARW"])
        let items = try FolderScanner.scan(folder: dir)
        let plan = ApplyEngine.plan(groups: BurstGrouper.group(items),
                                    decisions: ["A1_0002.JPG": .picked, "A1_0003.ARW": .picked])
        let engine = ApplyEngine(folder: dir)
        let applied = engine.apply(plan)
        var record = try #require(applied.record)
        let sorted = FolderSorter(folder: dir).sort(id: record.id, date: record.date)
        #expect(Set(sorted.moves.map(\.to)) == ["JPG/A1_0002.JPG", "RAW/A1_0002.ARW", "Del/A1_0003.ARW"])
        record.sortMoves = sorted.moves
        #expect(record.fileCount == 5)
        // アプリは記録を保存した後でジャーナルを片付ける
        engine.clearJournal()
        FolderSorter(folder: dir).clearJournal()

        let u = engine.undo(record)
        #expect(u.failures.isEmpty && u.restoredCount == 5 && u.remainingRecord == nil)
        for n in ["A1_0001.JPG", "A1_0001.ARW", "A1_0002.JPG", "A1_0002.ARW", "A1_0003.ARW"] { #expect(has(dir, n), "\(n)") }
        for d in ["_rejected", "JPG", "RAW", "Del"] { #expect(!has(dir, d), "\(d)") }
    }

    @Test("仕分けだけの記録（_rejected が無い）も取り消せる。戻せなかった分は残った記録に入る")
    func undoSortOnlyWithFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        touch(dir, ["A.JPG", "B.JPG"])
        let sorted = FolderSorter(folder: dir).sort(id: UUID(), date: Date())
        let record = ApplyRecord(date: Date(), moves: [], sortMoves: sorted.moves)
        touch(dir, ["B.JPG"])   // 戻し先をふさぐ

        let u = ApplyEngine(folder: dir).undo(record)
        #expect(u.restoredCount == 1)
        #expect(u.failures == [ApplyFailure(path: "JPG/B.JPG", reason: "戻し先に同じ名前のファイルがあります")])
        #expect(u.remainingRecord?.moves == [] && u.remainingRecord?.sortMoves == [MoveRecord(from: "B.JPG", to: "JPG/B.JPG")])
        #expect(has(dir, "A.JPG") && has(dir, "JPG/B.JPG") && !has(dir, "RAW") && !has(dir, "Del"))
    }

    @Test("取り消しは記録の形が不正な移動（フォルダの外・知らないサブフォルダ）を扱わない")
    func undoRejectsInvalidPaths() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = [MoveRecord(from: "A.JPG", to: "Other/A.JPG"), MoveRecord(from: "../A.JPG", to: "JPG/A.JPG"),
                   MoveRecord(from: "A.JPG", to: "JPG/../A.JPG")]
        let u = ApplyEngine(folder: dir).undo(ApplyRecord(date: Date(), moves: [], sortMoves: bad))
        #expect(u.restoredCount == 0 && u.failures.count == 3)
        #expect(u.failures.allSatisfy { $0.reason == "記録のパスが不正です" })
        #expect(u.remainingRecord?.sortMoves == bad)
    }

    @Test("途中で落ちたときは、ジャーナルから移動済みの分だけを復旧する")
    func recoversJournal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for d in FolderSorter.folderNames { try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
        // A は移し済み、B は予定のまま（元にある）、C は予定でだけ移し済み
        touch(dir.appendingPathComponent("JPG"), ["A.JPG", "C.JPG"])
        touch(dir, ["B.JPG"])
        let id = UUID()
        let journal = SortJournal(id: id, date: Date(timeIntervalSince1970: 0),
                                  moves: [MoveRecord(from: "A.JPG", to: "JPG/A.JPG")],
                                  pending: [MoveRecord(from: "B.JPG", to: "JPG/B.JPG"), MoveRecord(from: "C.JPG", to: "JPG/C.JPG")])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let sorter = FolderSorter(folder: dir)
        try enc.encode(journal).write(to: sorter.journalURL)

        guard case .recovered(let record) = sorter.recoverJournal() else {
            Issue.record("復旧されなかった")
            return
        }
        #expect(record.id == id && record.moves.isEmpty)
        #expect(record.sortMoves == [MoveRecord(from: "A.JPG", to: "JPG/A.JPG"), MoveRecord(from: "C.JPG", to: "JPG/C.JPG")])
        // ジャーナルは呼び出し側が保存してから片付ける
        #expect(fm.fileExists(atPath: sorter.journalURL.path))
        sorter.clearJournal()
        #expect(sorter.recoverJournal() == .none)
    }

    @Test("壊れたジャーナルは退避する")
    func brokenJournal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sorter = FolderSorter(folder: dir)
        try Data("{".utf8).write(to: sorter.journalURL)
        guard case .broken(let backup) = sorter.recoverJournal() else {
            Issue.record("退避されなかった")
            return
        }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: sorter.journalURL.path))
    }
}

@Suite("ApplyRecord の仕分けの記録")
struct SortRecordTests {
    @Test("appendSorted は同じ ID の記録に足し、同じ移動は二重に足さない。記録が無ければ新しく足す")
    func appendSorted() {
        let id = UUID()
        var s = SessionData(applied: [ApplyRecord(id: id, date: Date(), moves: [MoveRecord(from: "X.JPG", to: "_rejected/X.JPG")])])
        let a = MoveRecord(from: "A.JPG", to: "JPG/A.JPG")
        let b = MoveRecord(from: "B.JPG", to: "JPG/B.JPG")
        let added = [
            s.appendSorted(ApplyRecord(id: id, date: Date(), moves: [], sortMoves: [a])),
            s.appendSorted(ApplyRecord(id: id, date: Date(), moves: [], sortMoves: [a, b])),
            s.appendSorted(ApplyRecord(id: id, date: Date(), moves: [], sortMoves: [b])),
        ]
        #expect(added == [true, true, false])
        #expect(s.applied.count == 1 && s.applied[0].sortMoves == [a, b] && s.applied[0].moves.count == 1)

        let other = UUID()
        let addedNew = s.appendSorted(ApplyRecord(id: other, date: Date(), moves: [], sortMoves: [a]))
        let addedEmpty = s.appendSorted(ApplyRecord(id: UUID(), date: Date(), moves: [], sortMoves: []))
        #expect(addedNew && !addedEmpty)
        #expect(s.applied.last?.id == other && s.applied.count == 2)
    }

    @Test("仕分けの記録が先に入っていても、同じ ID の適用の復旧で _rejected の移動を足せる")
    func appendAppliedAfterSorted() {
        let id = UUID()
        var s = SessionData()
        s.appendSorted(ApplyRecord(id: id, date: Date(), moves: [], sortMoves: [MoveRecord(from: "A.JPG", to: "JPG/A.JPG")]))
        let x = MoveRecord(from: "X.JPG", to: "_rejected/X.JPG")
        let first = s.appendApplied(ApplyRecord(id: id, date: Date(), moves: [x]))
        let again = s.appendApplied(ApplyRecord(id: id, date: Date(), moves: [x]))
        #expect(first && !again)
        #expect(s.applied.count == 1 && s.applied[0].moves == [x] && s.applied[0].sortMoves.count == 1)
    }

    @Test("仕分けの無い記録は sortMoves を書かず、古い JSON（項目なし）も読める")
    func codingCompatibility() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let plain = ApplyRecord(date: Date(timeIntervalSince1970: 0), moves: [MoveRecord(from: "a", to: "_rejected/a")])
        let json = try #require(String(data: try enc.encode(plain), encoding: .utf8))
        #expect(!json.contains("sortMoves"))
        #expect(try dec.decode(ApplyRecord.self, from: Data(json.utf8)) == plain)

        let sorted = ApplyRecord(date: Date(timeIntervalSince1970: 0), moves: [], sortMoves: [MoveRecord(from: "a", to: "JPG/a")])
        #expect(try dec.decode(ApplyRecord.self, from: try enc.encode(sorted)) == sorted)
    }
}

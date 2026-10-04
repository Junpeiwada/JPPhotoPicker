import Testing
import Foundation
@testable import JPPhotoPickerCore

// MARK: - 補助

private func item(_ name: String, burst seq: Int? = nil, time: Double, ext: String = "JPG",
                  arw: Bool = false, mode: Int? = nil) -> PhotoItem {
    let dir = URL(fileURLWithPath: "/tmp/x")
    let meta = PhotoMetadata(
        captureDate: Date(timeIntervalSince1970: time),
        releaseMode: mode ?? (seq != nil ? 2 : 0),
        sequenceNumber: seq ?? 0)
    return PhotoItem(baseName: name,
                     jpgURL: ext == "ARW" ? nil : dir.appendingPathComponent("\(name).\(ext)"),
                     arwURL: (arw || ext == "ARW") ? dir.appendingPathComponent("\(name).ARW") : nil,
                     metadata: meta)
}

private func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("JPPhotoPickerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - フォルダ走査

@Suite("FolderScanner")
struct FolderScannerTests {
    @Test("ペア・JPGだけ・ARWだけに分け、隠しファイルと _rejected は除く")
    func scan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for n in ["A1_0001.JPG", "a1_0001.arw", "A1_0002.jpeg", "A1_0003.ARW", "A1_0004.jpg", "A1_0004.ARW",
                  ".hidden.jpg", "memo.txt", ".jpphotopicker.json"] {
            fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([0]))
        }
        try fm.createDirectory(at: dir.appendingPathComponent("_rejected"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("_rejected/A1_0009.JPG").path, contents: Data([0]))

        let items = try FolderScanner.scan(folder: dir)
        #expect(items.map(\.id) == ["A1_0001.JPG", "A1_0002.jpeg", "A1_0003.ARW", "A1_0004.jpg"])
        #expect(items.map(\.kind) == [.pair, .jpgOnly, .arwOnly, .pair])
        #expect(items[0].arwURL?.lastPathComponent == "a1_0001.arw")
        #expect(items[2].jpgURL == nil)
        #expect(items[2].primaryURL.lastPathComponent == "A1_0003.ARW")
        #expect(items[0].fileNumber == 1)
        #expect(items.allSatisfy { $0.metadata == nil })
    }

    @Test("ファイル番号は末尾の数字列")
    func trailingNumber() {
        #expect(PhotoItem.trailingNumber(of: "A1_07866") == 7866)
        #expect(PhotoItem.trailingNumber(of: "IMG_0001 (2)") == nil)
        #expect(PhotoItem.trailingNumber(of: "photo") == nil)
        #expect(PhotoItem.trailingNumber(of: "12345") == 12345)
    }

    @Test("サンプルフォルダを並列で読める", .enabled(if: sampleAvailable))
    func loadSampleFolder() async throws {
        let scanned = try FolderScanner.scan(folder: sampleFolder)
        #expect(scanned.count == 49)
        let items = await PhotoMetadataLoader.load(items: scanned)
        #expect(items.map(\.id) == scanned.map(\.id))
        #expect(items.allSatisfy { $0.metadata != nil })
    }
}

// MARK: - 並列読み込み

@Suite("PhotoMetadataLoader")
struct PhotoMetadataLoaderTests {
    private func makeItems(_ n: Int) -> [PhotoItem] {
        (0..<n).map {
            PhotoItem(baseName: String(format: "A1_%05d", $0),
                      jpgURL: URL(fileURLWithPath: "/tmp/x/A1_\(String(format: "%05d", $0)).JPG"), arwURL: nil)
        }
    }

    @Test("結果の順序は入力と同じで、全コマが埋まり、進捗は最後に (total, total)")
    func orderAndProgress() async {
        let items = makeItems(203)
        let maxSeen = LockedBox(0)
        let out = await PhotoMetadataLoader.load(items: items, reader: { item in
            // ファイル名の番号を Seq に入れて、順序の入れ替わりを検出する
            if item.fileNumber! % 7 == 0 { usleep(500) }
            return PhotoMetadata(sequenceNumber: item.fileNumber)
        }, progress: { done, total in
            #expect(total == 203)
            maxSeen.update { $0 = max($0, done) }
        })
        #expect(out.count == 203)
        #expect(out.map(\.id) == items.map(\.id))
        #expect(out.enumerated().allSatisfy { $0.element.metadata?.sequenceNumber == $0.offset })
        #expect(maxSeen.value == 203)
    }

    @Test("空の入力はそのまま返す")
    func empty() async {
        #expect(await PhotoMetadataLoader.load(items: []).isEmpty)
    }

    @Test("キャンセルすると打ち切って戻る（未処理は metadata nil）")
    func cancellation() async {
        let items = makeItems(4000)
        let calls = LockedBox(0)
        let task = Task {
            await PhotoMetadataLoader.load(items: items, reader: { item in
                calls.update { $0 += 1 }
                usleep(2000)
                return PhotoMetadata(sequenceNumber: item.fileNumber)
            })
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let out = await task.value
        #expect(out.count == items.count && out.map(\.id) == items.map(\.id))
        #expect(calls.value < items.count)
        // 読めたものは正しい値、読めなかったものは nil
        #expect(out.enumerated().allSatisfy { $0.element.metadata == nil || $0.element.metadata?.sequenceNumber == $0.offset })
        #expect(out.contains { $0.metadata == nil })
    }

    @Test("協調スレッドプールを塞がない: 遅い reader の最中でも他の async タスクが進む")
    func doesNotBlockCooperativePool() async {
        let items = makeItems(64)
        let loading = Task {
            await PhotoMetadataLoader.load(items: items, reader: { _ in usleep(20_000); return PhotoMetadata() })
        }
        // 読み込み中に、協調プール上の短いタスクを多数走らせて、待たされないことを確かめる
        let start = Date()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<200 { g.addTask { await Task.yield() } }
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
        _ = await loading.value
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

// MARK: - グループ化

@Suite("BurstGrouper")
struct BurstGrouperTests {
    @Test("サンプル49枚のグループ分けが期待どおり", .enabled(if: sampleAvailable))
    func sampleGroups() async throws {
        let items = await PhotoMetadataLoader.load(items: try FolderScanner.scan(folder: sampleFolder))
        let groups = BurstGrouper.group(items)
        #expect(groups.map { $0.items.map(\.baseName) } == sampleExpectedGroups)
        #expect(groups.map(\.id) == Array(0..<groups.count))
        let g = try #require(groups.first { $0.items.first?.baseName == "A1_07866" })
        #expect(g.isBurst && g.burstStartNumber == 7864 && g.items.count == 2)
        let g2 = try #require(groups.first { $0.items.first?.baseName == "A1_07873" })
        #expect(!g2.isBurst && g2.burstStartNumber == nil && g2.items.count == 1)   // 1 コマ連写は単写扱い
        #expect(groups.allSatisfy { $0.isBurst == ($0.items.count > 1) })
        let single = try #require(groups.first { $0.items.first?.baseName == "A1_04911" })
        #expect(!single.isBurst)
    }

    @Test("先頭番号が同じなら同じグループ、違えば別（調査.md の表）")
    func startNumbers() {
        let items = [
            item("A1_07866", burst: 3, time: 100.873),
            item("A1_07868", burst: 5, time: 100.973),
            item("A1_07873", burst: 4, time: 101.457),
        ]
        let g = BurstGrouper.group(items)
        #expect(g.map { $0.items.map(\.baseName) } == [["A1_07866", "A1_07868"], ["A1_07873"]])
        #expect(g.map(\.isBurst) == [true, false])   // 1 コマだけの連写は単写扱い
        #expect(g.map(\.burstStartNumber) == [7864, nil])
    }

    @Test("同時刻はファイル名順、単写は1枚1グループ")
    func tieAndSingles() {
        let items = [
            item("B_0003", time: 50),
            item("B_0002", time: 50),
            item("B_0001", time: 10),
        ]
        let g = BurstGrouper.group(items)
        #expect(g.map { $0.items.map(\.baseName) } == [["B_0001"], ["B_0002"], ["B_0003"]])
        #expect(g.allSatisfy { !$0.isBurst })
    }

    @Test("連写と単写が交互に並んでも連写を単写がまたがない")
    func singleBreaksBurst() {
        let items = [
            item("A_0010", burst: 1, time: 1),
            item("A_0011", time: 2),               // 単写
            item("A_0012", burst: 3, time: 3),     // 先頭番号 10 だが間に単写があるので別グループ
        ]
        let g = BurstGrouper.group(items)
        #expect(g.map { $0.items.count } == [1, 1, 1])
        #expect(g.map(\.isBurst) == [false, false, false])   // 1 コマだけの連写は単写扱い
    }

    @Test("ReleaseMode が連写でも Seq が 0 なら単写扱い")
    func seqZeroIsSingle() {
        let g = BurstGrouper.group([item("A_0001", burst: 0, time: 1, mode: 2)])
        #expect(!g[0].isBurst)
    }

    @Test("接頭辞が違えば、先頭番号が同じでも別グループ（L8）")
    func differentPrefixSameStart() {
        let items = [
            item("A1_0010", burst: 1, time: 1),
            item("A1_0011", burst: 2, time: 2),
            item("B1_0012", burst: 3, time: 3),    // 先頭番号は 10 だが、接頭辞が違う
            item("B1_0013", burst: 4, time: 4),
        ]
        #expect(items[0].namePrefix == "A1_" && items[2].namePrefix == "B1_")
        let g = BurstGrouper.group(items)
        #expect(g.map { $0.items.map(\.baseName) } == [["A1_0010", "A1_0011"], ["B1_0012", "B1_0013"]])
        #expect(g.map(\.burstStartNumber) == [10, 10])
    }

    @Test("接頭辞: 末尾の数字列の前の部分")
    func namePrefix() {
        #expect(PhotoItem.prefixBeforeTrailingDigits(of: "A1_07866") == "A1_")
        #expect(PhotoItem.prefixBeforeTrailingDigits(of: "photo") == "photo")
        #expect(PhotoItem.prefixBeforeTrailingDigits(of: "12345") == "")
        #expect(PhotoItem.prefixBeforeTrailingDigits(of: "IMG_0001 (2)") == "IMG_0001 (2)")
    }

    @Test("番号が取れないときは Seq が 1 か前以下で区切る")
    func noFileNumber() {
        let items = [
            item("alpha", burst: 1, time: 1),
            item("beta", burst: 2, time: 2),
            item("gamma", burst: 3, time: 3),
            item("delta", burst: 1, time: 4),
            item("epsilon", burst: 2, time: 5),
            item("zeta", burst: 2, time: 6),   // 前と同じ → 区切る
        ]
        let g = BurstGrouper.group(items)
        #expect(g.map { $0.items.map(\.baseName) }
                == [["alpha", "beta", "gamma"], ["delta", "epsilon"], ["zeta"]])
        #expect(g.map(\.isBurst) == [true, true, false])
        #expect(g.allSatisfy { $0.burstStartNumber == nil })
    }

    @Test("メタデータなし（ARW だけ等）は単写で末尾")
    func nilMetadata() {
        let noMeta = PhotoItem(baseName: "X_0001", jpgURL: nil,
                               arwURL: URL(fileURLWithPath: "/tmp/x/X_0001.ARW"), metadata: nil)
        let g = BurstGrouper.group([noMeta, item("A_0001", time: 5)])
        #expect(g.map { $0.items[0].baseName } == ["A_0001", "X_0001"])
        #expect(!g[1].isBurst)
    }
}

// MARK: - 判定と移動ルール

@Suite("Decision")
struct DecisionTests {
    @Test("1コマだけの連写グループは単写として扱う（移動のルールは同じで、採用以外を移す）")
    func singleFrameBurstIsSingle() {
        let items = [
            item("A_0010", burst: 1, time: 1),
            item("A_0011", burst: 2, time: 2),
            item("A_0020", burst: 2, time: 10),   // 先頭番号 19: 1 コマだけの連写
        ]
        let groups = BurstGrouper.group(items)
        #expect(groups.map(\.isBurst) == [true, false])
        #expect(groups[1].burstStartNumber == nil)
        let c1 = DecisionRules.moveCandidates(groups: groups, decisions: [:])
        #expect(c1.map(\.id) == ["A_0010.JPG", "A_0011.JPG", "A_0020.JPG"])   // 採用していない（不採用）コマは単写でも移す
        let c3 = DecisionRules.moveCandidates(groups: groups, decisions: ["A_0020.JPG": .picked])
        #expect(!c3.contains { $0.id == "A_0020.JPG" })
    }

    @Test("shouldMove: 採用以外を移す")
    func shouldMove() {
        #expect(DecisionRules.shouldMove(decision: .undecided))
        #expect(!DecisionRules.shouldMove(decision: .picked))
    }

    @Test("移動対象にペアの ARW が含まれ、ARW だけも対象になる")
    func candidates() {
        let items = [
            item("A_0001", burst: 1, time: 1, arw: true),
            item("A_0002", burst: 2, time: 2, arw: true),
            item("A_0003", burst: 3, time: 3),
            item("S_0100", time: 10, arw: true),
            item("S_0101", time: 11),
            item("R_0200", time: 20, ext: "ARW"),
        ]
        let groups = BurstGrouper.group(items)
        let decisions: [String: Decision] = [
            "A_0002.JPG": .picked,
        ]
        let c = DecisionRules.moveCandidates(groups: groups, decisions: decisions)
        #expect(c.map(\.id) == ["A_0001.JPG", "A_0003.JPG", "S_0100.JPG", "S_0101.JPG", "R_0200.ARW"])
        #expect(c[0].urls.map(\.lastPathComponent) == ["A_0001.JPG", "A_0001.ARW"])
        #expect(c[1].urls.map(\.lastPathComponent) == ["A_0003.JPG"])
        #expect(c[2].urls.map(\.lastPathComponent) == ["S_0100.JPG", "S_0100.ARW"])
        #expect(c[3].urls.map(\.lastPathComponent) == ["S_0101.JPG"])   // 単写の採用していない（不採用）コマも移す
        #expect(c[4].urls.map(\.lastPathComponent) == ["R_0200.ARW"])
        #expect(c[4].jpgURL == nil && c[4].arwURL != nil)
    }

    @Test("連写グループで1枚も採用しなければ全コマを移す")
    func noPickMovesAll() {
        let groups = BurstGrouper.group([item("A_0001", burst: 1, time: 1), item("A_0002", burst: 2, time: 2)])
        #expect(DecisionRules.moveCandidates(groups: groups, decisions: [:]).count == 2)
    }
}

// MARK: - 履歴

@Suite("DecisionHistory")
struct DecisionHistoryTests {
    @Test("undo/redo はどのコマかも返す")
    func undoRedo() {
        var book = DecisionBook()
        book.set(.picked, for: "a.JPG")
        book.set(.picked, for: "b.JPG")
        book.set(.undecided, for: "a.JPG")          // picked → undecided
        #expect(book.set(.undecided, for: "a.JPG") == nil)  // 変化なし

        let u1 = book.undo()
        #expect(u1 == DecisionChange(itemID: "a.JPG", from: .picked, to: .undecided))
        #expect(book.decision(for: "a.JPG") == .picked)
        let u2 = book.undo()
        #expect(u2?.itemID == "b.JPG" && book.decision(for: "b.JPG") == .undecided)
        let r = book.redo()
        #expect(r == DecisionChange(itemID: "b.JPG", from: .undecided, to: .picked))
        #expect(book.decision(for: "b.JPG") == .picked)
        #expect(book.history.canRedo)

        // 新しい変更でやり直しは消える
        book.set(.undecided, for: "a.JPG")
        #expect(!book.history.canRedo && book.redo() == nil)
        #expect(book.decisions == ["b.JPG": .picked])
    }

    @Test("履歴が空なら nil")
    func empty() {
        var h = DecisionHistory()
        #expect(h.undo() == nil && h.redo() == nil && !h.canUndo)
    }
}

// MARK: - 保存

@Suite("SessionStore")
struct SessionStoreTests {
    @Test("保存と読み込みの往復")
    func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(folder: dir)

        #expect(try store.load() == SessionData())   // ファイルが無ければ空

        let data = SessionData(
            decisions: ["A1_0001.JPG": .picked, "A1_0003.JPG": .picked],
            applied: [ApplyRecord(date: Date(timeIntervalSince1970: 1_790_000_000),
                                  moves: [MoveRecord(from: "A1_0002.JPG", to: "_rejected/A1_0002.JPG"),
                                          MoveRecord(from: "A1_0002.ARW", to: "_rejected/A1_0002.ARW")])])
        try store.save(data)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".jpphotopicker.json").path))
        #expect(try store.load() == data)

        // 上書き
        var d2 = data
        d2.decisions["A1_0003.JPG"] = .picked
        try store.save(d2)
        #expect(try store.load() == d2)
        // 一時ファイルが残らない
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == [".jpphotopicker.json"])
    }

    @Test("壊れたファイルは .broken-<日時> に退避してエラー（退避先を含む）。元ファイルは残る")
    func corrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        try Data("not json".utf8).write(to: url)
        do {
            _ = try SessionStore(folder: dir).load()
            Issue.record("エラーになるはず")
        } catch let SessionStoreError.corrupted(backup, _) {
            let b = try #require(backup)
            #expect(b.lastPathComponent.hasPrefix(".jpphotopicker.json.broken-"))
            let stamp = b.lastPathComponent.dropFirst(".jpphotopicker.json.broken-".count)
            #expect(stamp.count == 15 && stamp.dropFirst(8).first == "-")   // yyyyMMdd-HHmmss
            #expect(try Data(contentsOf: b) == Data("not json".utf8))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("decisions の未知の値は捨て、他は読める。applied も読める")
    func unknownDecisionValues() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"version":1,
         "decisions":{"a.JPG":"picked","b.JPG":"superstar","c.JPG":"rejected","d.JPG":"undecided","e.JPG":42},
         "applied":[]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(".jpphotopicker.json"))
        // 値が文字列でない要素があると全体は読めない（壊れた扱い）ので、e を除いたものを試す
        _ = try? SessionStore(folder: dir).load()
        let ok = json.replacingOccurrences(of: ",\"e.JPG\":42", with: "")
        try Data(ok.utf8).write(to: dir.appendingPathComponent(".jpphotopicker.json"))
        let s = try SessionStore(folder: dir).load()
        #expect(s.decisions == ["a.JPG": .picked])   // 以前の版の rejected は捨てる
    }

    @Test("将来の version は読めるが保存を拒否し、ファイルを書き換えない")
    func futureVersion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        let json = #"{"version":99,"decisions":{"a.JPG":"picked","b.JPG":"newthing"},"applied":[],"extra":{"x":1}}"#
        try Data(json.utf8).write(to: url)
        let store = SessionStore(folder: dir)
        let s = try store.load()
        #expect(s.version == 99)
        #expect(s.decisions == ["a.JPG": .picked])
        #expect(throws: SessionStoreError.unsupportedVersion(found: 99, supported: 1)) { try store.save(s) }
        // version を 1 にした別のデータでも、ディスク上が新しい版なら上書きしない
        #expect(throws: SessionStoreError.unsupportedVersion(found: 99, supported: 1)) { try store.save(SessionData()) }
        #expect(try Data(contentsOf: url) == Data(json.utf8))
        // 読めない将来版（applied の形が違う）でもエラーにせず、退避もしない
        let weird = #"{"version":99,"decisions":{},"applied":[{"when":"x"}]}"#
        try Data(weird.utf8).write(to: url)
        #expect(try store.load().version == 99)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".jpphotopicker.json"])
    }

    // MARK: - C10 / C11

    @Test("壊れたファイルを繰り返し開いても、同じ内容の退避ファイルは増えない")
    func brokenBackupIsNotDuplicated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PPStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent(".jpphotopicker.json"))
        var backups = Set<URL>()
        for _ in 0..<3 {
            do { _ = try SessionStore(folder: dir).load(); Issue.record("投げるはず") }
            catch let SessionStoreError.corrupted(b, _) { backups.insert(try #require(b)) }
        }
        #expect(backups.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".broken-") }
        #expect(names.count == 1)
        // 内容が変われば新しい退避を作る
        try Data("{ broken2".utf8).write(to: dir.appendingPathComponent(".jpphotopicker.json"))
        _ = try? SessionStore(folder: dir).load()
        let names2 = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".broken-") }
        #expect(names2.count == 2)
    }

    @Test("decisions・applied は要素ごとに壊れたものだけを捨てる")
    func lossyDecode() throws {
        let json = """
        {"version":1,
         "decisions":{"a.JPG":"picked","b.JPG":5,"c.JPG":null,"d.JPG":"rejected","e.JPG":"???","f.JPG":"undecided"},
         "applied":[
           {"date":"2026-09-29T00:00:00Z","moves":[{"from":"a.JPG","to":"_rejected/a.JPG"}]},
           {"date":"broken","moves":[]},
           {"moves":"x"},
           42
         ]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(SessionData.self, from: Data(json.utf8))
        #expect(s.decisions == ["a.JPG": .picked])
        #expect(s.applied.count == 1)
        #expect(s.applied[0].moves.count == 1)
    }

    // MARK: - 壊れた適用の記録

    /// 1 件目が正常、2 件目が壊れた適用の記録を持つ JSON
    private let jsonWithBrokenRecord = """
    {"version":1,"decisions":{"a.JPG":"picked"},
     "applied":[
       {"date":"2026-09-29T00:00:00Z","moves":[{"from":"b.JPG","to":"_rejected/b.JPG"}]},
       {"date":"broken","moves":[]}
     ]}
    """

    @Test("壊れた適用の記録を捨てたら、原本を .broken- に退避し、件数と退避先を返す")
    func droppedAppliedIsBackedUp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        try Data(jsonWithBrokenRecord.utf8).write(to: url)
        let store = SessionStore(folder: dir)

        let r = try store.loadWithReport()
        #expect(r.droppedAppliedCount == 1)
        #expect(r.session.applied.count == 1 && r.session.decisions == ["a.JPG": .picked])
        let b = try #require(r.backup)
        #expect(b.lastPathComponent.hasPrefix(".jpphotopicker.json.broken-"))
        #expect(try Data(contentsOf: b) == Data(jsonWithBrokenRecord.utf8))
        // 保存して記録が消えても、退避ファイルには残る
        try store.save(r.session)
        #expect(try Data(contentsOf: b) == Data(jsonWithBrokenRecord.utf8))
        // 保存後はもう捨てるものが無い
        let again = try store.loadWithReport()
        #expect(again.droppedAppliedCount == 0 && again.backup == nil)
    }

    @Test("load() でも壊れた記録を捨てたら原本を退避する。同じ内容なら退避ファイルは増えない")
    func droppedAppliedBackupViaLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(jsonWithBrokenRecord.utf8).write(to: dir.appendingPathComponent(".jpphotopicker.json"))
        let store = SessionStore(folder: dir)
        #expect(try store.load().applied.count == 1)
        _ = try store.load()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".broken-") }
        #expect(names.count == 1)
    }

    @Test("壊れた記録の退避に失敗しても読めた判定は返し、backupFailed を立てる。load() は corrupted を投げる")
    func droppedAppliedBackupFails() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        try Data(jsonWithBrokenRecord.utf8).write(to: url)
        // 書き込めないフォルダにして、退避ファイルを作れないようにする
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = SessionStore(folder: dir)

        let r = try store.loadWithReport()
        #expect(r.backupFailed && r.backup == nil && r.droppedAppliedCount == 1)
        #expect(r.session.decisions == ["a.JPG": .picked] && r.session.applied.count == 1)
        #expect(throws: SessionStoreError.corrupted(backup: nil, detail: "適用の記録 1 件が壊れています")) {
            try store.load()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".jpphotopicker.json"])
        #expect(try Data(contentsOf: url) == Data(jsonWithBrokenRecord.utf8))
    }

    @Test("壊れた記録が無ければ退避しない。新しい版のファイルは記録を捨てても退避しない")
    func noBackupWhenNothingDropped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        let store = SessionStore(folder: dir)
        try store.save(SessionData(applied: [ApplyRecord(date: Date(timeIntervalSince1970: 1_790_000_000), moves: [])]))
        let r = try store.loadWithReport()
        #expect(r.droppedAppliedCount == 0 && r.backup == nil && r.session.applied.count == 1)

        try Data(jsonWithBrokenRecord.replacingOccurrences(of: #""version":1"#, with: #""version":99"#).utf8).write(to: url)
        let future = try store.loadWithReport()
        #expect(future.session.version == 99 && future.droppedAppliedCount == 1 && future.backup == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".jpphotopicker.json"])
    }

    // MARK: - 再開位置・version の正規化

    @Test("lastViewedID: 往復で保たれ、nil なら書き出さない。旧形式（項目なし）は nil で読む")
    func lastViewedID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".jpphotopicker.json")
        let store = SessionStore(folder: dir)

        let data = SessionData(decisions: ["a.JPG": .picked], lastViewedID: "A1_0002.JPG")
        try store.save(data)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#""lastViewedID" : "A1_0002.JPG""#))
        #expect(try store.load() == data)

        try store.save(SessionData(decisions: ["a.JPG": .picked]))
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("lastViewedID"))
        #expect(try store.load().lastViewedID == nil)

        // 旧形式（この項目が無い）
        try Data(#"{"version":1,"decisions":{"a.JPG":"picked"},"applied":[]}"#.utf8).write(to: url)
        let old = try store.load()
        #expect(old.lastViewedID == nil && old.decisions == ["a.JPG": .picked] && old.version == 1)
        // 型が違っても全体は失敗させず nil
        try Data(#"{"version":1,"decisions":{},"applied":[],"lastViewedID":5}"#.utf8).write(to: url)
        #expect(try store.load().lastViewedID == nil)
    }

    @Test("save は古い version を currentVersion にそろえて書く（新しい版の拒否はそのまま）")
    func saveNormalizesVersion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(folder: dir)
        try store.save(SessionData(version: 0, decisions: ["a.JPG": .picked]))
        #expect(try store.load().version == SessionData.currentVersion)
        #expect(throws: SessionStoreError.unsupportedVersion(found: 2, supported: 1)) {
            try store.save(SessionData(version: 2))
        }
    }
}

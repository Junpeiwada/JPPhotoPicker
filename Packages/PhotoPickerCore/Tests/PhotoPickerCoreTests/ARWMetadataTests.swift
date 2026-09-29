import Testing
import Foundation
@testable import PhotoPickerCore

// MARK: - 合成 ARW（リトルエンディアンの TIFF 構造）

/// テスト用に ARW 相当のバイト列を組み立てる。
/// IFD0（Orientation・プレビュー・ExifIFD）→ ExifIFD（日時・MakerNote）→ MakerNote（Sony ヘッダー + タグ）
private struct SyntheticARW {
    var orientation = 6
    var releaseMode = 2
    var sequence = 6
    var withMakerNote = true
    var withPreview = true
    /// IFD1（480）と SubIFD（450）にもプレビュー候補を置く（L4: 最大の length を選ぶ）
    var withExtraPreviews = false
    /// SubIFD のプレビューの長さ
    var subPreviewLength = 99_999

    func build(padTo size: Int = 512) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        func p16(_ at: Int, _ v: Int) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8((v >> 8) & 0xFF) }
        func p32(_ at: Int, _ v: Int) { p16(at, v & 0xFFFF); p16(at + 2, (v >> 16) & 0xFFFF) }
        func entry(_ at: Int, tag: Int, type: Int, count: Int, value: Int) {
            p16(at, tag); p16(at + 2, type); p32(at + 4, count)
            if type == 3 { p16(at + 8, value) } else if type == 1 { b[at + 8] = UInt8(value) } else { p32(at + 8, value) }
        }
        func put(_ at: Int, _ bytes: [UInt8]) { for (k, v) in bytes.enumerated() { b[at + k] = v } }

        // ヘッダー
        put(0, [0x49, 0x49, 0x2A, 0x00]); p32(4, 8)

        // IFD0 @8
        var e0: [(Int, Int, Int, Int)] = [(0x0112, 3, 1, orientation)]
        if withPreview { e0 += [(0x0201, 4, 1, 5000), (0x0202, 4, 1, 1234)] }
        if withExtraPreviews { e0.append((0x014A, 4, 1, 450)) }
        e0.append((0x8769, 4, 1, 100))
        p16(8, e0.count)
        for (k, e) in e0.enumerated() { entry(10 + k * 12, tag: e.0, type: e.1, count: e.2, value: e.3) }
        if withExtraPreviews {
            p32(10 + e0.count * 12, 480)   // 次の IFD = IFD1
            p16(480, 2)
            entry(482, tag: 0x0201, type: 4, count: 1, value: 7000)
            entry(494, tag: 0x0202, type: 4, count: 1, value: 5000)
            p16(450, 2)
            entry(452, tag: 0x0201, type: 4, count: 1, value: 9000)
            entry(464, tag: 0x0202, type: 4, count: 1, value: subPreviewLength)
        }

        // ExifIFD @100
        var e1: [(Int, Int, Int, Int)] = [(0x9003, 2, 20, 200), (0x9011, 2, 7, 220)]
        if withMakerNote { e1.append((0x927C, 7, 12 + 54 + 4 + 8 + 6, 300)) }
        e1.append((0x9291, 2, 4, 0))
        p16(100, e1.count)
        for (k, e) in e1.enumerated() { entry(102 + k * 12, tag: e.0, type: e.1, count: e.2, value: e.3) }
        put(102 + (e1.count - 1) * 12 + 8, Array("351".utf8) + [0])   // SubSec（4 バイトに収まるので直接）
        put(200, Array("2026:09:29 12:34:56".utf8) + [0])
        put(220, Array("+09:00".utf8) + [0])

        if withMakerNote {
            put(300, Array("SONY DSC ".utf8) + [0, 0, 0])
            // IFD @312、エントリ 4 件 → 2 + 48 + 4 = 54 バイト。値領域は 400 以降
            p16(312, 4)
            entry(314, tag: 0x2027, type: 7, count: 8, value: 400)
            entry(326, tag: 0x2037, type: 7, count: 6, value: 410)
            entry(338, tag: 0xB049, type: 1, count: 1, value: releaseMode)
            entry(350, tag: 0xB04A, type: 1, count: 1, value: sequence)
            for (k, v) in [8640, 4864, 4563, 2918].enumerated() { p16(400 + k * 2, v) }
            for (k, v) in [189, 193, 257].enumerated() { p16(410 + k * 2, v) }
        }
        return b
    }
}

private func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoPickerARW-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Double {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        .timeIntervalSince1970
}

// MARK: - 読み取り

/// 他ファイルのテストから使う、合成 ARW のバイト列（512 バイト。プレビューは範囲外を指す）
enum SyntheticARWForEOF {
    static var bytesWithoutMakerNote: [UInt8] {
        var s = SyntheticARW()
        s.withMakerNote = false
        return s.build()
    }
}

@Suite("ARWMetadataReader")
struct ARWMetadataTests {
    @Test("合成データから日時・Orientation・MakerNote・プレビュー位置を読める")
    func parseSynthetic() throws {
        let m = try #require(ARWMetadataReader.parse(prefix: Data(SyntheticARW().build())))
        #expect(m.orientation == 6)
        #expect(m.releaseMode == 2)
        #expect(m.sequenceNumber == 6)
        #expect(m.isBurstFrame)
        #expect(m.focusLocation == FocusLocation(width: 8640, height: 4864, x: 4563, y: 2918))
        #expect(m.focusFrameSize == FocusFrameSize(width: 189, height: 193, flag: 257))
        #expect(m.mpfPreview == FileRange(offset: 5000, length: 1234))
        let t = try #require(m.captureDate).timeIntervalSince1970
        // 12:34:56.351 +09:00 = 03:34:56.351 UTC
        #expect(abs(t - (utc(2026, 9, 29, 3, 34, 56) + 0.351)) < 0.0005)
    }

    @Test("MakerNote もプレビューも無い ARW は、読めた分だけ返す")
    func partial() throws {
        var s = SyntheticARW()
        s.withMakerNote = false
        s.withPreview = false
        let m = try #require(ARWMetadataReader.parse(prefix: Data(s.build())))
        #expect(m.captureDate != nil)
        #expect(m.releaseMode == nil)
        #expect(m.focusLocation == nil)
        #expect(m.mpfPreview == nil)
        #expect(m.orientation == 6)
    }

    @Test("プレビュー候補（IFD0・IFD1・SubIFD）のうち最大の length を選ぶ")
    func largestPreview() throws {
        var s = SyntheticARW()
        s.withExtraPreviews = true
        let m = try #require(ARWMetadataReader.parse(prefix: Data(s.build())))
        #expect(m.mpfPreview == FileRange(offset: 9000, length: 99_999))
        s.subPreviewLength = 10          // SubIFD が小さければ IFD1（5000）より IFD0 の 1234 ではなく 5000 が最大
        let m2 = try #require(ARWMetadataReader.parse(prefix: Data(s.build())))
        #expect(m2.mpfPreview == FileRange(offset: 7000, length: 5000))
        // 従来どおり IFD0 だけのときは IFD0
        let m3 = try #require(ARWMetadataReader.parse(prefix: Data(SyntheticARW().build())))
        #expect(m3.mpfPreview == FileRange(offset: 5000, length: 1234))
    }

    @Test("プレビュー候補: ファイル内に収まるものの中から最大を選ぶ（ファイルサイズが分かるとき）")
    func largestPreviewInsideFile() throws {
        var s = SyntheticARW()
        s.withExtraPreviews = true      // IFD0: (5000,1234) IFD1: (7000,5000) SubIFD: (9000,99999)
        let bytes = s.build()
        // 大きさ 13_000 のファイル: SubIFD（9000+99999）は外、IFD1（7000+5000=12000）が最大
        let m = try #require(ARWMetadataReader.parse(bytes: bytes, fileSize: 13_000))
        #expect(m.mpfPreview == FileRange(offset: 7000, length: 5000))
        // 全部外なら nil
        let m2 = try #require(ARWMetadataReader.parse(bytes: bytes, fileSize: 100))
        #expect(m2.mpfPreview == nil)
    }

    @Test("read(url:): プレビューがファイルの外なら nil、TIFF でなければ notTIFF")
    func readValidations() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("A1_0001.ARW")
        try Data(SyntheticARW().build()).write(to: url)   // プレビュー（5000+1234）は 512 バイトのファイルの外
        let m = try ARWMetadataReader.read(url: url)
        #expect(m.mpfPreview == nil && m.sequenceNumber == 6)
        // ファイルの中に収まるなら残る
        try Data(SyntheticARW().build(padTo: 8000)).write(to: url)
        #expect(try ARWMetadataReader.read(url: url).mpfPreview == FileRange(offset: 5000, length: 1234))

        let bad = dir.appendingPathComponent("A1_0002.ARW")
        try Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 0, 0, 0, 0, 0]).write(to: bad)
        #expect(throws: MetadataError.notTIFF) { _ = try ARWMetadataReader.read(url: bad) }
    }

    @Test("TIFF でないデータは nil")
    func notTIFF() {
        #expect(ARWMetadataReader.parse(prefix: Data()) == nil)
        #expect(ARWMetadataReader.parse(prefix: Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 0, 0, 0, 0, 0])) == nil)
    }

    @Test("途中で切れたデータ・壊れたデータでも落ちない")
    func robustness() {
        let full = SyntheticARW().build()
        for n in stride(from: 0, through: full.count, by: 7) {
            _ = ARWMetadataReader.parse(prefix: Data(full[0..<n]))
        }
        // 全バイトをでたらめな値にしたものを、ヘッダーだけ正しくして何度も読む
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var b = full
            for _ in 0..<20 { b[Int.random(in: 8..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = ARWMetadataReader.parse(prefix: Data(b))
        }
        // IFD のエントリ数が巨大
        var big = full
        big[8] = 0xFF; big[9] = 0xFF
        _ = ARWMetadataReader.parse(prefix: Data(big))
    }

    @Test("ファイルから読める。MakerNote が先頭 256KB の外にあっても追加読みで届く")
    func readFromFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("A1_0001.ARW")
        try Data(SyntheticARW().build()).write(to: url)
        let m = try ARWMetadataReader.read(url: url)
        #expect(m.sequenceNumber == 6)

        // MakerNote の値領域を 300KB 先に置いた別データ: 位置をずらして組み立て直す
        var far = SyntheticARW().build(padTo: 400_000)
        // ExifIFD の MakerNote エントリ（3 番目、添字 2）のオフセットを書き換え、本体を 300000 へ複製する
        let moved = 300_000
        let note = Array(far[300..<300 + 12 + 54 + 4 + 8 + 6 + 40])
        for (k, v) in note.enumerated() { far[moved + k] = v }
        // MakerNote 内の値オフセットは TIFF 基準なので、相対位置を維持するため IFD の値位置も更新する
        func p32(_ at: Int, _ v: Int) { for k in 0..<4 { far[at + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        p32(102 + 2 * 12 + 8, moved)
        p32(moved + 12 + 2 + 8, moved + 100)      // 0x2027 の値位置
        p32(moved + 12 + 2 + 12 + 8, moved + 110) // 0x2037 の値位置
        for k in 0..<8 { far[moved + 100 + k] = far[400 + k] }
        for k in 0..<6 { far[moved + 110 + k] = far[410 + k] }
        let url2 = dir.appendingPathComponent("A1_0002.ARW")
        try Data(far).write(to: url2)
        let m2 = try ARWMetadataReader.read(url: url2)
        #expect(m2.releaseMode == 2)
        #expect(m2.focusLocation?.x == 4563)
    }

    @Test("defaultReader は ARW だけのコマで ARWMetadataReader を使う")
    func defaultReaderForARWOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let arw = dir.appendingPathComponent("A1_0001.ARW")
        try Data(SyntheticARW().build()).write(to: arw)
        let item = PhotoItem(baseName: "A1_0001", jpgURL: nil, arwURL: arw)
        let m = PhotoMetadataLoader.defaultReader(item)
        #expect(m?.sequenceNumber == 6)
        // 壊れた ARW は nil
        let bad = dir.appendingPathComponent("A1_0002.ARW")
        try Data([1, 2, 3]).write(to: bad)
        #expect(PhotoMetadataLoader.defaultReader(PhotoItem(baseName: "A1_0002", jpgURL: nil, arwURL: bad)) == nil)
    }

    @Test("ARW だけのコマは連写グループに混ざり、移動対象では ARW だけが移る")
    func arwOnlyInGroupsAndRules() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        func it(_ n: String, seq: Int, t: Double, arwOnly: Bool) -> PhotoItem {
            PhotoItem(baseName: n,
                      jpgURL: arwOnly ? nil : dir.appendingPathComponent("\(n).JPG"),
                      arwURL: dir.appendingPathComponent("\(n).ARW"),
                      metadata: PhotoMetadata(captureDate: Date(timeIntervalSince1970: t), releaseMode: 2, sequenceNumber: seq))
        }
        let groups = BurstGrouper.group([
            it("A1_0101", seq: 1, t: 1, arwOnly: false),
            it("A1_0102", seq: 2, t: 2, arwOnly: true),
            it("A1_0103", seq: 3, t: 3, arwOnly: false),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].isBurst)
        let cands = DecisionRules.moveCandidates(groups: groups, decisions: ["A1_0101.JPG": .picked])
        #expect(cands.map(\.id) == ["A1_0102.ARW", "A1_0103.JPG"])
        #expect(cands[0].urls.map(\.lastPathComponent) == ["A1_0102.ARW"])
        #expect(cands[0].jpgURL == nil)
        let plan = ApplyPlan(candidates: cands)
        #expect(plan.jpgCount == 1)
        #expect(plan.arwCount == 2)
    }
}

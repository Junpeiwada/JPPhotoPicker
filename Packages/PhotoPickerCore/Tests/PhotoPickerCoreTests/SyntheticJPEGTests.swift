import Testing
import Foundation
@testable import PhotoPickerCore

private func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoPickerJPEG-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ bytes: [UInt8], named name: String = "A1_0001.JPG", in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

/// 2026-09-29 12:34:56.351 +09:00
private let expectedTime = 1_790_652_896.351

private func check(_ m: PhotoMetadata, _ s: SyntheticJPEG, _ built: SyntheticJPEG.Built,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(m.orientation == s.orientation, sourceLocation: sourceLocation)
    #expect(m.releaseMode == s.releaseMode && m.sequenceNumber == s.sequence, sourceLocation: sourceLocation)
    #expect(m.focusLocation == FocusLocation(width: s.focusLocation[0], height: s.focusLocation[1],
                                             x: s.focusLocation[2], y: s.focusLocation[3]),
            sourceLocation: sourceLocation)
    #expect(m.focusFrameSize == FocusFrameSize(width: s.focusFrameSize[0], height: s.focusFrameSize[1],
                                               flag: s.focusFrameSize[2]),
            sourceLocation: sourceLocation)
    #expect(m.thumbnail == built.thumbnail, sourceLocation: sourceLocation)
    #expect(m.mpfPreview == built.preview, sourceLocation: sourceLocation)
    #expect(m.imageWidth == 8640, sourceLocation: sourceLocation)
    let t = m.captureDate?.timeIntervalSince1970 ?? 0
    #expect(abs(t - expectedTime) < 0.0005, sourceLocation: sourceLocation)
}

@Suite("合成 JPEG によるパーサー検証（サンプル不要）")
struct SyntheticJPEGTests {
    @Test("リトルエンディアン・ビッグエンディアンの両方で、Exif・MakerNote・サムネイル・MPF を読める", arguments: [true, false])
    func bothEndians(le: Bool) throws {
        var s = SyntheticJPEG()
        s.littleEndian = le
        let built = s.build()
        #expect(built.thumbnail != nil && built.preview != nil)
        let m = try JPEGMetadataReader.parse(prefix: Data(built.bytes), isCompleteFile: true)
        check(m, s, built)
        #expect(m.isBurstFrame)

        // ファイルからも同じ結果で、サムネイルと MPF の範囲は JPEG（SOI〜EOI）を指す
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(built.bytes, in: dir)
        let f = try JPEGMetadataReader.read(url: url)
        #expect(f == m)
        for r in [try #require(f.thumbnail), try #require(f.mpfPreview)] {
            let d = try r.readData(from: url)
            #expect(d.count == r.length)
            #expect(d.first == 0xFF && d[d.startIndex + 1] == 0xD8)
            #expect(d[d.endIndex - 2] == 0xFF && d.last == 0xD9)
        }
    }

    @Test("MP Entry が 1 件だけなら mpfPreview は nil（他は読める）", arguments: [true, false])
    func singleMPEntry(le: Bool) throws {
        var s = SyntheticJPEG()
        s.littleEndian = le
        s.mpEntryCount = 1
        let built = s.build()
        let m = try JPEGMetadataReader.parse(prefix: Data(built.bytes), isCompleteFile: true)
        #expect(built.preview == nil && m.mpfPreview == nil)
        check(m, s, built)
    }

    @Test("MPF 2 枚目の属性: JPEG 形式かつ種別コードが Large Thumbnail なら受け入れ、bit30 は必須にしない")
    func mpEntryAttribute() throws {
        func preview(_ attr: UInt32) throws -> FileRange? {
            var s = SyntheticJPEG()
            s.secondEntryAttribute = attr
            return try JPEGMetadataReader.parse(prefix: Data(s.build().bytes), isCompleteFile: true).mpfPreview
        }
        #expect(try preview(0x4001_0002) != nil)   // Sony の実測値（従属子・JPEG・Large Thumbnail）
        #expect(try preview(0x0001_0002) != nil)   // 従属フラグ（bit30）が無くても可
        #expect(try preview(0x0001_0001) != nil)   // Large Thumbnail (class 1)
        #expect(try preview(0x4000_0000) == nil)   // 種別コードが Large Thumbnail でない
        #expect(try preview(0x4002_0000) == nil)   // 種別コードが Large Thumbnail でない（Panorama など）
        #expect(try preview(0x4100_0002) == nil)   // 画像データ形式が JPEG でない
    }

    @Test("MPF が無い JPEG でも Exif は読める")
    func noMPF() throws {
        var s = SyntheticJPEG()
        s.withMPF = false
        s.withThumbnail = false
        let built = s.build()
        let m = try JPEGMetadataReader.parse(prefix: Data(built.bytes), isCompleteFile: true)
        #expect(m.mpfPreview == nil && m.thumbnail == nil)
        #expect(m.sequenceNumber == 6 && m.orientation == 6)
    }

    @Test("APP1 が初期読み込み量（64KB）をまたぐ・外にあっても、追加読みで届く", arguments: [
        1_000, 64_000, 65_400, 70_000, 200_000,
    ])
    func needMorePath(padding: Int) throws {
        var s = SyntheticJPEG()
        s.leadingPadding = padding
        let built = s.build()
        // 前置きの大きさによって、ヘッダー・セグメント本体・MPF のどこで足りなくなるかが変わる
        if padding >= 64_000 { #expect(built.bytes.count > JPEGMetadataReader.initialReadSize) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(built.bytes, in: dir)
        let m = try JPEGMetadataReader.read(url: url)
        check(m, s, built)
        // 部分データだけを渡すと needMore になる（isCompleteFile: false で切れていれば truncated）
        if built.bytes.count > 70_000 {
            #expect(throws: MetadataError.truncated) {
                _ = try JPEGMetadataReader.parse(prefix: Data(built.bytes[0..<40_000]))
            }
        }
    }

    @Test("Exif の IFD ポインタ（型 13）も読める")
    func ifdPointerType13() throws {
        var s = SyntheticJPEG()
        s.exifPointerType = 13
        let built = s.build()
        let m = try JPEGMetadataReader.parse(prefix: Data(built.bytes), isCompleteFile: true)
        check(m, s, built)
    }

    @Test("FocusLocation の宣言サイズが足りなければ読まない（L3）")
    func declaredSizeTooSmall() throws {
        var s = SyntheticJPEG()
        s.focusLocationType = 1     // BYTE × 4 = 4 バイトしかない
        let m = try JPEGMetadataReader.parse(prefix: Data(s.build().bytes), isCompleteFile: true)
        #expect(m.focusLocation == nil)
        #expect(m.focusFrameSize != nil && m.sequenceNumber == 6)
    }

    @Test("サムネイル・MPF の範囲がファイルの外なら read(url:) は nil にする（L1）")
    func rangesOutsideFile() throws {
        var s = SyntheticJPEG()
        s.thumbnailLengthOverride = 5_000_000
        s.previewLengthOverride = 9_000_000
        let built = s.build()
        // メモリ上の解析ではファイルの大きさが分からないので、値は返る
        let mem = try JPEGMetadataReader.parse(prefix: Data(built.bytes), isCompleteFile: true)
        #expect(mem.thumbnail?.length == 5_000_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try JPEGMetadataReader.read(url: try write(built.bytes, in: dir))
        #expect(m.thumbnail == nil && m.mpfPreview == nil)
        #expect(m.sequenceNumber == 6)
    }

    @Test("FileRange.fits")
    func fileRangeFits() {
        #expect(FileRange(offset: 10, length: 90).fits(inFileOfSize: 100))
        #expect(!FileRange(offset: 10, length: 91).fits(inFileOfSize: 100))
        #expect(!FileRange(offset: 101, length: 1).fits(inFileOfSize: 100))
        #expect(!FileRange(offset: 0, length: 0).fits(inFileOfSize: 100))
        #expect(!FileRange(offset: Int.max, length: 2).fits(inFileOfSize: 100))
    }

    @Test("途中で切れたデータ・ランダムに壊したデータでも落ちない", arguments: [true, false])
    func robustness(le: Bool) {
        var s = SyntheticJPEG()
        s.littleEndian = le
        let full = s.build().bytes
        // すべての長さで切る
        for n in 0...full.count {
            _ = try? JPEGMetadataReader.parse(prefix: Data(full[0..<n]))
            if n % 13 == 0 { _ = try? JPEGMetadataReader.parse(prefix: Data(full[0..<n]), isCompleteFile: true) }
        }
        // ランダムなバイト変異（固定シードで再現可能）
        var rng = SplitMix64(seed: le ? 1 : 2)
        for _ in 0..<2000 {
            var b = full
            for _ in 0..<Int.random(in: 1...30, using: &rng) {
                b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? JPEGMetadataReader.parse(prefix: Data(b), isCompleteFile: true)
            _ = try? JPEGMetadataReader.parse(prefix: Data(b))
        }
        // ヘッダー直後から完全にでたらめ
        for _ in 0..<200 {
            let n = Int.random(in: 2...400, using: &rng)
            let b: [UInt8] = [0xFF, 0xD8] + (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = try? JPEGMetadataReader.parse(prefix: Data(b), isCompleteFile: true)
        }
    }

    @Test("壊れたファイルを read(url:) しても落ちない（追加読みの経路）")
    func robustnessFromFile() throws {
        var s = SyntheticJPEG()
        s.leadingPadding = 70_000
        let full = s.build().bytes
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SplitMix64(seed: 7)
        for i in 0..<40 {
            var b = full
            if i % 2 == 0 { b.removeLast(Int.random(in: 1..<(full.count - 4), using: &rng)) }
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? JPEGMetadataReader.read(url: try write(b, in: dir))
        }
    }

    // MARK: 日付（L15）

    @Test("日付: 範囲外の時分秒・月日は nil、ASCII 数字以外は nil")
    func dateValidation() throws {
        func p(_ s: String, sub: String? = nil, off: String? = "+00:00") -> Date? {
            JPEGMetadataReader.parseDate(s, subSec: sub, offset: off)
        }
        #expect(p("2026:09:29 12:34:56") != nil)
        #expect(p("2026:09:29 24:00:00") == nil)
        #expect(p("2026:09:29 12:60:00") == nil)
        #expect(p("2026:09:29 12:00:60") == nil)
        #expect(p("2026:13:01 00:00:00") == nil)
        #expect(p("2026:02:30 00:00:00") == nil)
        #expect(p("2024:02:29 00:00:00") != nil)
        #expect(p("2026:00:10 00:00:00") == nil)
        #expect(p("２０２６:09:29 12:34:56") == nil)      // 全角数字
        #expect(p("2026:09:29 1a:34:56") == nil)
        // SubSec は ASCII 数字だけ。全角は無視
        let a = try #require(p("2026:09:29 12:34:56", sub: "５００"))
        let b = try #require(p("2026:09:29 12:34:56"))
        #expect(a == b)
        let c = try #require(p("2026:09:29 12:34:56", sub: "5"))
        #expect(abs(c.timeIntervalSince(b) - 0.5) < 1e-6)
        // 不正なオフセットは現在のタイムゾーンとして扱う（クラッシュしない）
        _ = p("2026:09:29 12:34:56", off: "+９９:００")
        _ = p("2026:09:29 12:34:56", off: "+99:99")
    }

    // MARK: - C1: 読み込み中にファイルが縮んだ（EOF）

    @Test("JPEG: 読み込み中にファイルが縮んでも無限ループせず、EOF までで解析して失敗する")
    func shrinkingFileDoesNotLoop() throws {
        let bytes = SyntheticJPEG().build().bytes
        // 申告サイズは大きいが、実際は先頭 100 バイトしか読めない（Exif の途中で切れる）
        let cut = Array(bytes.prefix(100))
        var calls = 0
        // EOF で isCompleteFile: true として最後に 1 回解析するので、Exif が無ければ noExif
        #expect(throws: MetadataError.noExif) {
            _ = try JPEGMetadataReader.read(fileSize: bytes.count + 1_000_000) { offset, count in
                calls += 1
                #expect(calls < 50)
                guard offset < cut.count else { return Data() }
                return Data(cut[offset..<min(cut.count, offset + count)])
            }
        }
        #expect(calls < 50)
    }

    @Test("JPEG: 縮んだあとのファイルでも、Exif まで読めていれば EOF で 1 回だけ解析して結果を返す")
    func shrunkFileStillParsesWhatItHas() throws {
        let built = SyntheticJPEG().build()
        let full = built.bytes
        var calls = 0
        let m = try JPEGMetadataReader.read(fileSize: full.count + 5_000_000) { offset, count in
            calls += 1
            #expect(calls < 50)
            guard offset < full.count else { return Data() }
            return Data(full[offset..<min(full.count, offset + count)])
        }
        #expect(m.releaseMode != nil)
        #expect(calls < 50)
    }

    @Test("ARW: 読み込み中にファイルが縮んでも無限ループしない")
    func shrinkingARWDoesNotLoop() throws {
        var calls = 0
        let full = SyntheticARWForEOF.bytesWithoutMakerNote   // MakerNote が無いので「読み足りない」扱いになる
        let m = try ARWMetadataReader.read(fileSize: 50_000_000) { offset, count in
            calls += 1
            #expect(calls < 50)
            guard offset < full.count else { return Data() }
            return Data(full[offset..<min(full.count, offset + count)])
        }
        // 申告サイズ外を指すプレビュー（offset 5000, length 1234 は実サイズ 512 の外）は捨てられる
        #expect(m.mpfPreview == nil)
        #expect(calls < 50)
    }
}

/// 再現可能な乱数
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

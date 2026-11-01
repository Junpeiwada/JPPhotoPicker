import Testing
import Foundation
@testable import JPPhotoPickerCore

// MARK: - 合成 ORF（リトルエンディアン、"IIRO" ヘッダー）

/// IFD0（Orientation・ExifIFD）→ ExifIFD（日時・MakerNote）→ Olympus MakerNote
/// （ヘッダー + メイン IFD → CameraSettings / ImageProcessing のサブ IFD）を組み立てる。
/// MakerNote の宣言長は実機と同じく埋め込みプレビューを含む大きさ（`makerNoteCount`）にでき、実体はバッファの外でもよい
private struct SyntheticORF {
    var orientation = 6
    /// AFPointSelected の (x, y)（分子 / 分母）
    var af: (Int, Int, Int, Int) = (249, 640, 355, 480)
    var aspectFrame = [0, 164, 3999, 2835]
    var omSystem = false
    var makerNoteCount = 1_511_404
    /// MakerNote の位置（ファイル先頭から）
    static let note = 1000

    func build(size: Int = 4096) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        func p16(_ at: Int, _ v: Int) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8((v >> 8) & 0xFF) }
        func p32(_ at: Int, _ v: Int) { p16(at, v & 0xFFFF); p16(at + 2, (v >> 16) & 0xFFFF) }
        func entry(_ at: Int, tag: Int, type: Int, count: Int, value: Int) {
            p16(at, tag); p16(at + 2, type); p32(at + 4, count)
            if type == 3 && count == 1 { p16(at + 8, value) } else { p32(at + 8, value) }
        }
        func put(_ at: Int, _ bytes: [UInt8]) { for (k, v) in bytes.enumerated() { b[at + k] = v } }

        put(0, [0x49, 0x49, 0x52, 0x4F]); p32(4, 8)
        // IFD0 @8
        p16(8, 2)
        entry(10, tag: 0x0112, type: 3, count: 1, value: orientation)
        entry(22, tag: 0x8769, type: 4, count: 1, value: 100)
        // ExifIFD @100
        p16(100, 2)
        entry(102, tag: 0x9003, type: 2, count: 20, value: 200)
        entry(114, tag: 0x927C, type: 7, count: makerNoteCount, value: Self.note)
        put(200, Array("2026:10:29 12:40:46".utf8) + [0])

        // MakerNote @1000。以下のオフセットは MakerNote 先頭基準
        let n = Self.note
        let header = omSystem
            ? Array("OM SYSTEM".utf8) + [0, 0, 0, 0x49, 0x49, 4, 0]
            : Array("OLYMPUS".utf8) + [0, 0x49, 0x49, 3, 0]
        put(n, header)
        let main = n + header.count
        p16(main, 2)
        entry(main + 2, tag: 0x2020, type: 13, count: 1, value: 100)    // CameraSettings @n+100
        entry(main + 14, tag: 0x2040, type: 13, count: 1, value: 400)   // ImageProcessing @n+400
        // CameraSettings: プレビュー有効・開始・長さ、AFPointSelected（srational[5] @n+300）
        let cs = n + 100
        p16(cs, 4)
        entry(cs + 2, tag: 0x0100, type: 4, count: 1, value: 1)
        entry(cs + 14, tag: 0x0101, type: 4, count: 1, value: 49132)
        entry(cs + 26, tag: 0x0102, type: 4, count: 1, value: 1_179_920)
        entry(cs + 38, tag: 0x0305, type: 10, count: 5, value: 300)
        for (k, v) in [0, 0, af.0, af.1, af.2, af.3, af.0, af.1, af.2, af.3].enumerated() { p32(n + 300 + k * 4, v) }
        // ImageProcessing: AspectFrame（int16u[4] @n+500）
        let ip = n + 400
        p16(ip, 1)
        entry(ip + 2, tag: 0x1113, type: 3, count: 4, value: 500)
        for (k, v) in aspectFrame.enumerated() { p16(n + 500 + k * 2, v) }
        return b
    }
}

/// 読み取り要求のうち最も遠い終端を記録しつつ、バッファの外はゼロで埋めて返す
private final class ReadLog: @unchecked Sendable {
    var maxEnd = 0
}

private func readORF(_ bytes: [UInt8], fileSize: Int, log: ReadLog) throws -> PhotoMetadata {
    try RAWMetadataReader.read(fileSize: fileSize) { offset, count in
        log.maxEnd = max(log.maxEnd, offset + count)
        var out = [UInt8](repeating: 0, count: count)
        for k in 0..<count where offset + k < bytes.count { out[k] = bytes[offset + k] }
        return Data(out)
    }
}

@Suite("Olympus MakerNote（合成データ）")
struct OlympusSyntheticTests {
    @Test("ORF から AF の点・埋め込みプレビュー・切り出し後の大きさ・向きを読む")
    func orf() throws {
        let m = try #require(RAWMetadataReader.parse(bytes: SyntheticORF().build(), fileSize: 10_000_000))
        #expect(m.orientation == 6)
        let p = try #require(m.olympusAFPoint)
        #expect(abs(p.x - 249.0 / 640) < 1e-9 && abs(p.y - 355.0 / 480) < 1e-9)
        #expect(abs(p.frameAspect - 4.0 / 3) < 1e-9)
        #expect(m.mpfPreview == FileRange(offset: SyntheticORF.note + 49132, length: 1_179_920))
        #expect(m.imageWidth == 4000 && m.imageHeight == 2672)
        #expect(m.focusLocation == nil && m.releaseMode == nil)
        #expect(m.captureDate != nil)
    }

    @Test("OM SYSTEM のヘッダー（16 バイト）でも読む")
    func omSystem() throws {
        let m = try #require(RAWMetadataReader.parse(bytes: SyntheticORF(omSystem: true).build(), fileSize: 10_000_000))
        #expect(m.olympusAFPoint != nil && m.imageWidth == 4000)
    }

    @Test("MakerNote 全体（1.5MB）は読まず、先頭の 256KB で済ませる")
    func readsOnlyPrefix() throws {
        let log = ReadLog()
        let m = try readORF(SyntheticORF().build(), fileSize: 20_000_000, log: log)
        #expect(m.olympusAFPoint != nil)
        #expect(log.maxEnd <= RAWMetadataReader.initialReadSize)
    }

    @Test("AFPointSelected の分母が 0（n/a）なら点なし")
    func afNotAvailable() throws {
        let m = try #require(RAWMetadataReader.parse(bytes: SyntheticORF(af: (0, 0, 0, 0)).build()))
        #expect(m.olympusAFPoint == nil)
        #expect(FocusGeometry(metadata: m) == .centered)
    }

    @Test("Olympus でない MakerNote には反応しない（Sony として読む）")
    func notOlympus() {
        var bytes = SyntheticORF().build()
        bytes[SyntheticORF.note] = 0x58   // "XLYMPUS"
        #expect(OlympusMakerNote.parse(data: bytes, start: SyntheticORF.note) == nil)
    }
}

@Suite("FocusGeometry（Olympus）")
struct OlympusFocusGeometryTests {
    private let point = OlympusAFPoint(x: 249.0 / 640, y: 355.0 / 480, frameAspect: 4.0 / 3)

    @Test("4:3 の座標を 3:2 に切り出した画像の座標に換算する（上下を切る）")
    func crop3x2() {
        let g = FocusGeometry(olympus: point, imageWidth: 4000, imageHeight: 2672, orientation: 1)
        let f = (4.0 / 3) / (4000.0 / 2672)
        #expect(g.hasFocusPosition)
        #expect(abs(g.center.x - 249.0 / 640) < 1e-9)
        #expect(abs(g.center.y - (355.0 / 480 - (1 - f) / 2) / f) < 1e-9)
        // 枠は短辺（高さ）の 6% の正方形
        let size = try! #require(g.frameSize)
        #expect(abs(size.height - 0.06) < 1e-9 && abs(size.width - 0.06 * 2672 / 4000) < 1e-9)
    }

    @Test("画像の大きさが無いときは座標系のまま")
    func noImageSize() {
        let g = FocusGeometry(olympus: point, imageWidth: nil, imageHeight: nil, orientation: 1)
        #expect(abs(g.center.y - 355.0 / 480) < 1e-9)
        #expect(abs(g.frameSize!.width - 0.06 * 3 / 4) < 1e-9)
    }

    @Test("縦位置（Orientation 6）は中心を回し、枠の縦横を入れ替える")
    func rotated() {
        let flat = FocusGeometry(olympus: point, imageWidth: 4000, imageHeight: 2672, orientation: 1)
        let g = FocusGeometry(olympus: point, imageWidth: 4000, imageHeight: 2672, orientation: 6)
        #expect(g.center == FocusGeometry.transform(flat.center, orientation: 6))
        #expect(g.frameSize == NormalizedSize(width: flat.frameSize!.height, height: flat.frameSize!.width))
    }

    @Test("切り出しの外にある点は位置なし")
    func outside() {
        let top = OlympusAFPoint(x: 0.5, y: 0.01, frameAspect: 4.0 / 3)
        #expect(FocusGeometry(olympus: top, imageWidth: 4000, imageHeight: 2672, orientation: 1) == .centered)
        // 1:1 に切り出したときは左右を切る
        let left = OlympusAFPoint(x: 0.05, y: 0.5, frameAspect: 4.0 / 3)
        #expect(FocusGeometry(olympus: left, imageWidth: 3000, imageHeight: 3000, orientation: 1) == .centered)
    }

    @Test("Sony の FocusLocation があればそちらを使う")
    func sonyWins() {
        let m = PhotoMetadata(focusLocation: FocusLocation(width: 100, height: 100, x: 10, y: 20),
                              focusFrameSize: FocusFrameSize(width: 10, height: 10, flag: 257),
                              olympusAFPoint: point)
        #expect(abs(FocusGeometry(metadata: m).center.x - 0.1) < 1e-9)
    }
}

// MARK: - 実機サンプル（TG-6。外付けドライブにあるときだけ。読み取りのみ）

let olympusSampleFolder = URL(fileURLWithPath: "/Volumes/DriveStation9T/一時保管所/2026-10-30/100OLYMP")

var olympusSampleAvailable: Bool {
    FileManager.default.fileExists(atPath: olympusSampleFolder.appendingPathComponent("PA290001.ORF").path)
}

@Suite("Olympus 実機サンプル（TG-6）", .enabled(if: olympusSampleAvailable))
struct OlympusSampleTests {
    /// exiftool の実測値: ファイル名、Orientation、AFPointSelected（分子 / 640, 分子 / 480）
    static let table: [(String, Int, Int, Int)] = [
        ("PA290001", 1, 319, 239),
        ("PA290003", 1, 249, 355),
        ("PA290007", 6, 249, 355),
        ("PA290009", 1, 319, 181),
    ]

    @Test("JPG と ORF の両方から同じ AF の点と向きを読む")
    func afPoint() throws {
        for (name, orientation, x, y) in Self.table {
            for ext in ["JPG", "ORF"] {
                let url = olympusSampleFolder.appendingPathComponent("\(name).\(ext)")
                let m = ext == "JPG" ? try JPEGMetadataReader.read(url: url) : try RAWMetadataReader.read(url: url)
                #expect(m.orientation == orientation, "\(name).\(ext)")
                let p = try #require(m.olympusAFPoint, "\(name).\(ext)")
                #expect(abs(p.x - Double(x) / 640) < 1e-9 && abs(p.y - Double(y) / 480) < 1e-9, "\(name).\(ext)")
                #expect(abs(p.frameAspect - 4.0 / 3) < 1e-9)
                #expect(m.imageWidth == 4000 && m.imageHeight == 2672, "\(name).\(ext)")
                #expect(m.captureDate != nil)
            }
        }
    }

    @Test("ORF の埋め込みプレビューの位置（exiftool: PreviewImageStart 52224 / Length 1179920）")
    func orfPreview() throws {
        let m = try RAWMetadataReader.read(url: olympusSampleFolder.appendingPathComponent("PA290001.ORF"))
        #expect(m.mpfPreview == FileRange(offset: 52224, length: 1_179_920))
        let data = try #require(try m.mpfPreview?.readData(from: olympusSampleFolder.appendingPathComponent("PA290001.ORF")))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }
}

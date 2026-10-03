import Foundation
@testable import JPPhotoPickerCore

/// テスト用に Sony 風の JPEG（SOI + APP1 Exif + APP2 MPF + SOS + 末尾に MPF 2 枚目）を組み立てる。
/// 実サンプルが無い環境でも、パーサーの経路（II/MM・MakerNote・サムネイル・MPF・追加読み）を検証するためのもの。
struct SyntheticJPEG {
    var littleEndian = true
    var orientation = 6
    var dateTimeOriginal = "2026:09:29 12:34:56"
    var subSec = "351"
    var offsetTime = "+09:00"
    var releaseMode = 2
    var sequence = 6
    var focusLocation = [8640, 4864, 4563, 2918]
    var focusFrameSize = [189, 193, 257]
    /// 0x2027 の型（3 = SHORT が正常）。count は 4 固定なので、型を 1 にすると宣言サイズが不足する（L3）
    var focusLocationType = 3
    /// ExifIFD へのポインタの型（4 = LONG、13 = IFD）
    var exifPointerType = 4
    var withMakerNote = true
    var withThumbnail = true
    /// MPF の MP Entry の件数（2 が正常。1 だと 2 枚目が無い）
    var mpEntryCount = 2
    /// 2 枚目の MP Entry の属性（0x40010002 = 従属画像・JPEG・Large Thumbnail）
    var secondEntryAttribute: UInt32 = 0x4001_0002
    var withMPF = true
    /// SOI の直後に置く COM セグメントの大きさ（各 65000 バイト以下に分割）。APP1 を先頭 64KB の外へ押し出すのに使う
    var leadingPadding = 0
    /// サムネイルの長さを上書き（ファイルの外を指す値を作る）
    var thumbnailLengthOverride: Int?
    /// MPF 2 枚目の長さを上書き
    var previewLengthOverride: Int?

    static let thumbnailBody = 300
    static let previewBody = 2000

    struct Built {
        var bytes: [UInt8]
        var thumbnail: FileRange?
        var preview: FileRange?
    }

    // MARK: 組み立て

    private struct Buf {
        var b: [UInt8] = []
        let le: Bool
        mutating func ensure(_ n: Int) { if b.count < n { b += [UInt8](repeating: 0, count: n - b.count) } }
        mutating func p16(_ at: Int, _ v: Int) {
            ensure(at + 2)
            b[at] = UInt8(truncatingIfNeeded: le ? v : v >> 8)
            b[at + 1] = UInt8(truncatingIfNeeded: le ? v >> 8 : v)
        }
        mutating func p32(_ at: Int, _ v: Int) {
            ensure(at + 4)
            for k in 0..<4 {
                let shift = le ? 8 * k : 8 * (3 - k)
                b[at + k] = UInt8(truncatingIfNeeded: v >> shift)
            }
        }
        mutating func put(_ at: Int, _ bytes: [UInt8]) {
            ensure(at + bytes.count)
            for (k, v) in bytes.enumerated() { b[at + k] = v }
        }
    }

    private struct Entry {
        var tag: Int
        var type: Int
        var count: Int
        /// 4 バイト以内ならその場に置く値（type/count に応じた形）。オフセットなら offset
        var value: Int
        /// 4 バイト以内の生バイト（指定時は value を無視）
        var raw: [UInt8]?
    }

    private func writeIFD(_ buf: inout Buf, at start: Int, entries: [Entry], next: Int) {
        buf.p16(start, entries.count)
        for (k, e) in entries.enumerated() {
            let p = start + 2 + k * 12
            buf.p16(p, e.tag); buf.p16(p + 2, e.type); buf.p32(p + 4, e.count)
            if let raw = e.raw {
                buf.put(p + 8, raw)
            } else if e.type == 3, e.count == 1 {
                buf.p16(p + 8, e.value)
            } else if e.type == 1, e.count == 1 {
                buf.put(p + 8, [UInt8(truncatingIfNeeded: e.value)])
            } else {
                buf.p32(p + 8, e.value)
            }
        }
        buf.p32(start + 2 + entries.count * 12, next)
    }

    private static func ifdSize(_ n: Int) -> Int { 2 + 12 * n + 4 }

    /// Exif の TIFF 部分。戻り値は (TIFF バイト列, サムネイルの TIFF 内位置)
    private func buildExifTIFF() -> (bytes: [UInt8], thumb: FileRange?) {
        var buf = Buf(le: littleEndian)
        buf.put(0, littleEndian ? [0x49, 0x49] : [0x4D, 0x4D])
        buf.p16(2, 42); buf.p32(4, 8)

        let n0 = 3, nE = 4, n1 = withThumbnail ? 2 : 0
        let ifd0 = 8
        let exifIFD = ifd0 + Self.ifdSize(n0)
        let ifd1 = exifIFD + Self.ifdSize(nE)
        var cursor = ifd1 + (withThumbnail ? Self.ifdSize(n1) : 0)

        let dtPos = cursor; cursor += 20
        let offPos = cursor; cursor += 8
        let notePos = cursor
        let noteIFDSize = Self.ifdSize(4)
        let noteValues = 12 + noteIFDSize
        let noteLength = noteValues + 8 + 6
        if withMakerNote { cursor += noteLength }
        let thumbPos = cursor
        let thumbLen = Self.thumbnailBody + 4

        writeIFD(&buf, at: ifd0, entries: [
            Entry(tag: 0x0112, type: 3, count: 1, value: orientation, raw: nil),
            Entry(tag: 0x8769, type: exifPointerType, count: 1, value: exifIFD, raw: nil),
            Entry(tag: 0x0100, type: 4, count: 1, value: 8640, raw: nil),
        ], next: withThumbnail ? ifd1 : 0)

        var exifEntries = [
            Entry(tag: 0x9003, type: 2, count: 20, value: dtPos, raw: nil),
            Entry(tag: 0x9011, type: 2, count: 7, value: offPos, raw: nil),
            Entry(tag: 0x9291, type: 2, count: 4, value: 0, raw: Array(subSec.utf8.prefix(3)) + [0]),
        ]
        exifEntries.insert(
            Entry(tag: 0x927C, type: 7, count: noteLength, value: notePos, raw: nil), at: 2)
        if !withMakerNote { exifEntries.remove(at: 2) }
        let exifCount = exifEntries.count
        // n の見積り（nE = 4）と実際の件数が違うとき、ifd1 の位置がずれるので固定する
        precondition(exifCount <= nE)
        writeIFD(&buf, at: exifIFD, entries: exifEntries, next: 0)

        buf.put(dtPos, Array(dateTimeOriginal.utf8) + [0])
        buf.put(offPos, Array(offsetTime.utf8) + [0])

        if withMakerNote {
            buf.put(notePos, Array("SONY DSC ".utf8) + [0, 0, 0])
            let ifdAt = notePos + 12
            let vals = notePos + noteValues
            writeIFD(&buf, at: ifdAt, entries: [
                Entry(tag: 0x2027, type: focusLocationType, count: 4, value: vals, raw: nil),
                Entry(tag: 0x2037, type: 3, count: 3, value: vals + 8, raw: nil),
                Entry(tag: 0xB049, type: 1, count: 1, value: releaseMode, raw: nil),
                Entry(tag: 0xB04A, type: 1, count: 1, value: sequence, raw: nil),
            ], next: 0)
            for (k, v) in focusLocation.enumerated() { buf.p16(vals + k * 2, v) }
            for (k, v) in focusFrameSize.enumerated() { buf.p16(vals + 8 + k * 2, v) }
        }

        var thumbRange: FileRange?
        if withThumbnail {
            writeIFD(&buf, at: ifd1, entries: [
                Entry(tag: 0x0201, type: 4, count: 1, value: thumbPos, raw: nil),
                Entry(tag: 0x0202, type: 4, count: 1, value: thumbnailLengthOverride ?? thumbLen, raw: nil),
            ], next: 0)
            buf.put(thumbPos, [0xFF, 0xD8] + [UInt8](repeating: 0x11, count: Self.thumbnailBody) + [0xFF, 0xD9])
            thumbRange = FileRange(offset: thumbPos, length: thumbnailLengthOverride ?? thumbLen)
        }
        return (buf.b, thumbRange)
    }

    /// MPF の TIFF 部分。`previewOffset` は MPF ヘッダー基準の 2 枚目のオフセット
    private func buildMPF(previewOffset: Int, previewLength: Int, totalSize: Int) -> [UInt8] {
        var buf = Buf(le: littleEndian)
        buf.put(0, littleEndian ? [0x49, 0x49] : [0x4D, 0x4D])
        buf.p16(2, 42); buf.p32(4, 8)
        let entryData = 8 + Self.ifdSize(3)
        writeIFD(&buf, at: 8, entries: [
            Entry(tag: 0xB000, type: 7, count: 4, value: 0, raw: Array("0100".utf8)),
            Entry(tag: 0xB001, type: 4, count: 1, value: mpEntryCount, raw: nil),
            Entry(tag: 0xB002, type: 7, count: 16 * mpEntryCount, value: entryData, raw: nil),
        ], next: 0)
        func entry(_ i: Int, attr: UInt32, size: Int, offset: Int) {
            let p = entryData + i * 16
            buf.p32(p, Int(attr)); buf.p32(p + 4, size); buf.p32(p + 8, offset)
        }
        entry(0, attr: 0x2003_0000, size: totalSize, offset: 0)
        if mpEntryCount >= 2 { entry(1, attr: secondEntryAttribute, size: previewLength, offset: previewOffset) }
        return buf.b
    }

    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let len = payload.count + 2
        precondition(len <= 0xFFFF)
        return [0xFF, marker, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    func build() -> Built {
        var out: [UInt8] = [0xFF, 0xD8]
        var remaining = leadingPadding
        while remaining > 0 {
            let n = min(remaining, 60_000)
            out += segment(0xFE, [UInt8](repeating: 0x20, count: n))
            remaining -= n
        }

        let exif = buildExifTIFF()
        let app1Payload = Array("Exif".utf8) + [0, 0] + exif.bytes
        let app1Start = out.count
        out += segment(0xE1, app1Payload)
        let tiffBase = app1Start + 4 + 6
        let thumb = exif.thumb.map { FileRange(offset: tiffBase + $0.offset, length: $0.length) }

        var preview: FileRange?
        if withMPF {
            // APP2 のサイズは、オフセットの値によらず一定（各値は 4 バイト固定）
            let probe = buildMPF(previewOffset: 0, previewLength: 0, totalSize: 0)
            let app2Start = out.count
            let mpfBase = app2Start + 4 + 4
            let app2Size = 4 + 4 + probe.count
            let sos: [UInt8] = [0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00, 0x12, 0x34, 0xFF, 0xD9]
            let previewPos = app2Start + app2Size + sos.count
            let previewLen = Self.previewBody + 4
            let total = previewPos + previewLen
            let mpf = buildMPF(previewOffset: previewPos - mpfBase,
                               previewLength: previewLengthOverride ?? previewLen, totalSize: total)
            out += segment(0xE2, Array("MPF".utf8) + [0] + mpf)
            out += sos
            out += [0xFF, 0xD8] + [UInt8](repeating: 0x22, count: Self.previewBody) + [0xFF, 0xD9]
            if mpEntryCount >= 2, (secondEntryAttribute >> 24) & 7 == 0, [0x010001, 0x010002].contains(secondEntryAttribute & 0xFFFFFF) {
                preview = FileRange(offset: previewPos, length: previewLengthOverride ?? previewLen)
            }
        } else {
            out += [0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00, 0x12, 0x34, 0xFF, 0xD9]
        }
        return Built(bytes: out, thumbnail: thumb, preview: preview)
    }
}

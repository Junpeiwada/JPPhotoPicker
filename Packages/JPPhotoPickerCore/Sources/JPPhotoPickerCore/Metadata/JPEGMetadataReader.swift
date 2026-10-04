import Foundation

public enum MetadataError: Error, Sendable, Equatable {
    case notJPEG
    case noExif
    case truncated
    /// TIFF（ARW など）として読めない
    case notTIFF
}

/// JPEG の先頭だけを読み、Exif / Sony MakerNote / MPF の情報を取り出す。
public enum JPEGMetadataReader {
    /// 最初に読むバイト数（APP1 は約 44KB、MPF はその直後にある）。足りなければ `needMore` で増やす
    static let initialReadSize = 64 * 1024
    /// これ以上は読まない
    static let maxReadSize = 8 * 1024 * 1024

    /// ファイルの先頭から必要な分だけ読んでメタデータを返す。
    public static func read(url: URL) throws -> PhotoMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        return try read(fileSize: fileSize) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    /// 読み取り関数（offset, count → Data）を注入できる本体。テストでは読み込み中にファイルが縮む状況を模擬する。
    /// 読み取りが空を返したら EOF とみなし、そこまでのバイト列を「ファイル全体」として最後に 1 回だけ解析する。
    static func read(fileSize declaredSize: Int,
                     readAt: (_ offset: Int, _ count: Int) throws -> Data) throws -> PhotoMetadata {
        var fileSize = declaredSize
        var request = min(initialReadSize, fileSize)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(request)
        var reachedEOF = false
        while true {
            // 先頭から読み直さず、足りない差分だけを追加で読む
            if bytes.count < request {
                let more = try readAt(bytes.count, request - bytes.count)
                if more.isEmpty {
                    // 読み込み中にファイルが縮んだ。ここまでを全体として扱う
                    reachedEOF = true
                    fileSize = bytes.count
                    request = bytes.count
                } else {
                    bytes.append(contentsOf: more)
                }
            }
            switch try parse(bytes: bytes, isCompleteFile: reachedEOF || bytes.count >= fileSize) {
            case .done(var m):
                // ファイルの外を指すサムネイル・プレビューは無効にする
                if let t = m.thumbnail, !t.fits(inFileOfSize: fileSize) { m.thumbnail = nil }
                if let p = m.mpfPreview, !p.fits(inFileOfSize: fileSize) { m.mpfPreview = nil }
                return m
            case .needMore(let n):
                guard !reachedEOF, n <= maxReadSize, request < fileSize else { throw MetadataError.truncated }
                request = min(max(n, request * 2), fileSize, maxReadSize)
            }
        }
    }

    /// メモリ上のバイト列（ファイル先頭部分）を解析する。
    static func parse(prefix: Data, isCompleteFile: Bool = false) throws -> PhotoMetadata {
        switch try parse(bytes: [UInt8](prefix), isCompleteFile: isCompleteFile) {
        case .done(let m): return m
        case .needMore: throw MetadataError.truncated
        }
    }

    enum ParseResult {
        case done(PhotoMetadata)
        case needMore(Int)
    }

    static func parse(bytes: [UInt8], isCompleteFile: Bool) throws -> ParseResult {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw MetadataError.notJPEG }

        var metadata = PhotoMetadata()
        var haveExif = false
        var haveMPF = false
        var i = 2

        func be16(_ p: Int) -> Int { Int(bytes[p]) << 8 | Int(bytes[p + 1]) }

        while true {
            // 次のセグメントのヘッダー（FF xx LL LL）が読めるか
            if i + 4 > bytes.count {
                if isCompleteFile { break }
                return .needMore(i + 4 + 64 * 1024)
            }
            guard bytes[i] == 0xFF else { break }
            var p = i
            while p + 1 < bytes.count, bytes[p + 1] == 0xFF { p += 1 }   // フィルバイト
            guard p + 4 <= bytes.count else {
                if isCompleteFile { break }
                return .needMore(p + 4 + 64 * 1024)
            }
            let marker = bytes[p + 1]
            if marker == 0xD9 || marker == 0xDA { break }               // EOI / SOS
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i = p + 2; continue }
            let length = be16(p + 2)
            let segStart = p + 4
            let segEnd = p + 2 + length
            guard length >= 2 else { break }
            if segEnd > bytes.count {
                if isCompleteFile { break }
                return .needMore(segEnd)
            }

            if marker == 0xE1, !haveExif, segEnd - segStart >= 6,
               bytes[segStart..<segStart + 6].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                parseExif(bytes: bytes, tiffBase: segStart + 6, into: &metadata)
                haveExif = true
            } else if marker == 0xE2, !haveMPF, segEnd - segStart >= 4,
                      bytes[segStart..<segStart + 4].elementsEqual([0x4D, 0x50, 0x46, 0]) {
                parseMPF(bytes: bytes, tiffBase: segStart + 4, into: &metadata)
                haveMPF = true
            }
            i = segEnd
            if haveExif && haveMPF { break }
            // Exif を得た後に MPF を探して大きく進みすぎない
            if haveExif && i > 1024 * 1024 { break }
        }

        guard haveExif else { throw MetadataError.noExif }
        return .done(metadata)
    }

    // MARK: - Exif

    private static func parseExif(bytes: [UInt8], tiffBase: Int, into m: inout PhotoMetadata) {
        guard let tiff = TIFFReader(data: bytes, base: tiffBase),
              let ifd0Off = tiff.firstIFDOffset,
              let (ifd0, next) = tiff.readIFD(atOffset: ifd0Off) else { return }

        if let e = ifd0.entry(0x0112), let o = tiff.firstInt(e), (1...8).contains(o) { m.orientation = o }
        if let e = ifd0.entry(0x0100) { m.imageWidth = tiff.firstInt(e) }
        if let e = ifd0.entry(0x0101) { m.imageHeight = tiff.firstInt(e) }

        // IFD1（サムネイル）
        if let next, let (ifd1, _) = tiff.readIFD(atAbsolute: next),
           let oe = ifd1.entry(0x0201), let le = ifd1.entry(0x0202),
           let off = tiff.firstInt(oe), let len = tiff.firstInt(le), len > 0 {
            m.thumbnail = FileRange(offset: tiffBase + off, length: len)
        }

        // ExifIFD
        guard let pe = ifd0.entry(0x8769), let exifOff = tiff.firstInt(pe),
              let (exif, _) = tiff.readIFD(atOffset: exifOff) else { return }

        if let e = exif.entry(0xA002), let w = tiff.firstInt(e) { m.imageWidth = w }
        if let e = exif.entry(0xA003), let h = tiff.firstInt(e) { m.imageHeight = h }

        if let e = exif.entry(0x9003), let s = tiff.string(e) {
            let sub = exif.entry(0x9291).flatMap { tiff.string($0) }
            let offset = exif.entry(0x9011).flatMap { tiff.string($0) }
            m.captureDate = parseDate(s, subSec: sub, offset: offset)
        }

        if let e = exif.entry(0x927C),
           let v = SonyMakerNote.parse(tiff: tiff, start: e.valueIndex, length: e.count) {
            m.releaseMode = v.releaseMode
            m.sequenceNumber = v.sequenceNumber
            m.focusLocation = v.focusLocation
            m.focusFrameSize = v.focusFrameSize
        }
    }

    // MARK: - MPF

    private static func parseMPF(bytes: [UInt8], tiffBase: Int, into m: inout PhotoMetadata) {
        guard let tiff = TIFFReader(data: bytes, base: tiffBase),
              let off = tiff.firstIFDOffset,
              let (entries, _) = tiff.readIFD(atOffset: off),
              let mpEntry = entries.entry(0xB002), mpEntry.type == 7,
              mpEntry.count >= 32 else { return }
        // MP Entry: 16 バイト × 枚数（属性 4, サイズ 4, オフセット 4, 従属 2+2）。2 枚目 = 添字 1
        let p = mpEntry.valueIndex + 16
        guard let attr = tiff.u32(p), let size = tiff.u32(p + 4), let offset = tiff.u32(p + 8), size > 0 else { return }
        // 属性: bit26-24 = 画像データ形式（0 = JPEG）、下位 24 bit = 種別コード。
        // 0x010001 = Large Thumbnail (class 1)、0x010002 = Large Thumbnail (class 2)。Sony の 2 枚目は 0x40010002。
        // bit30（従属画像フラグ）は実装により付かないことがあるので必須にしない。
        guard (attr >> 24) & 0x7 == 0, [0x010001, 0x010002].contains(attr & 0xFFFFFF) else { return }
        // オフセットは MPF ヘッダー（TIFF ヘッダー）位置基準
        m.mpfPreview = FileRange(offset: tiffBase + offset, length: size)
    }

    // MARK: - 日付

    /// "YYYY:MM:DD HH:MM:SS" + SubSec + "+09:00" を Date にする。
    /// オフセットが無いときは現在のタイムゾーンとして扱う。
    static func parseDate(_ s: String, subSec: String?, offset: String?) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for k in r {
                guard b[k] >= 48, b[k] <= 57 else { return nil }
                v = v * 10 + Int(b[k] - 48)
            }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19),
              (1...12).contains(mo), (1...daysInMonth(y, mo)).contains(d),
              (0...23).contains(h), (0...59).contains(mi), (0...59).contains(sec) else { return nil }

        var fraction = 0.0
        if let subSec {
            let digits = subSec.utf8.prefix { $0 >= 48 && $0 <= 57 }.prefix(9)
            if !digits.isEmpty, let n = Double("0." + String(decoding: digits, as: UTF8.self)) { fraction = n }
        }

        let localSeconds = Double(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec)
        var tzSeconds: Int?
        if let offset {
            let o = Array(offset.utf8)
            func d2(_ a: Int) -> Int? {
                guard o[a] >= 48, o[a] <= 57, o[a + 1] >= 48, o[a + 1] <= 57 else { return nil }
                return Int(o[a] - 48) * 10 + Int(o[a + 1] - 48)
            }
            if o.count >= 6, o[0] == 0x2B || o[0] == 0x2D, o[3] == 0x3A,
               let oh = d2(1), let om = d2(4), oh <= 14, om <= 59 {
                tzSeconds = (oh * 3600 + om * 60) * (o[0] == 0x2D ? -1 : 1)
            }
        }
        let tz: Int
        if let tzSeconds {
            tz = tzSeconds
        } else {
            tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: localSeconds))
        }
        return Date(timeIntervalSince1970: localSeconds - Double(tz) + fraction)
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 1970-01-01 からの日数（グレゴリオ暦）
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

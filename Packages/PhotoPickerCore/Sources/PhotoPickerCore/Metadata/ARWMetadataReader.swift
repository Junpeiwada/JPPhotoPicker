import Foundation

/// Sony ARW（TIFF 構造）の先頭だけを読み、Exif / Sony MakerNote / 埋め込みプレビューの位置を取り出す。
/// 実機サンプルで確認できていないタグは、読めなければ nil として扱い、例外では落とさない。
public enum ARWMetadataReader {
    /// 最初に読むバイト数
    static let initialReadSize = 256 * 1024
    /// これ以上は読まない
    static let maxReadSize = 8 * 1024 * 1024

    /// ファイルの先頭から必要な分だけ読んでメタデータを返す。
    /// MakerNote まで届かなければ、読む量を増やして再挑戦する。
    public static func read(url: URL) throws -> PhotoMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        return try read(fileSize: fileSize) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    /// 読み取り関数を注入できる本体。読み取りが空を返したら EOF とみなし、そこまでの解析結果を返す。
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
                    reachedEOF = true
                    fileSize = bytes.count
                    request = bytes.count
                } else {
                    bytes.append(contentsOf: more)
                }
            }
            guard var result = parse(bytes: bytes, fileSize: fileSize) else { throw MetadataError.notTIFF }
            let complete = result.releaseMode != nil && result.captureDate != nil
            if complete || reachedEOF || bytes.count >= fileSize || request >= maxReadSize {
                if let p = result.mpfPreview, !p.fits(inFileOfSize: fileSize) { result.mpfPreview = nil }
                return result
            }
            request = min(request * 4, fileSize, maxReadSize)
        }
    }

    /// メモリ上のバイト列（ファイル先頭部分）を解析する。TIFF として読めなければ nil。
    public static func parse(prefix: Data) -> PhotoMetadata? {
        parse(bytes: [UInt8](prefix))
    }

    static func parse(bytes: [UInt8], fileSize: Int? = nil) -> PhotoMetadata? {
        guard let tiff = TIFFReader(data: bytes, base: 0),
              let ifd0Off = tiff.firstIFDOffset,
              let (ifd0, next) = tiff.readIFD(atOffset: ifd0Off) else { return nil }

        var m = PhotoMetadata()
        if let e = ifd0.entry(0x0112), let o = tiff.firstInt(e), (1...8).contains(o) { m.orientation = o }

        // 埋め込みプレビュー: IFD0 → IFD1 → SubIFD の候補をすべて集め、ファイル内に収まるもののうちいちばん大きい（length 最大）ものを選ぶ
        // （オフセットはファイル先頭基準）
        var previews: [FileRange] = []
        if let r = previewRange(tiff, ifd0) { previews.append(r) }
        if let next, let (ifd1, _) = tiff.readIFD(atAbsolute: next), let r = previewRange(tiff, ifd1) {
            previews.append(r)
        }
        if let se = ifd0.entry(0x014A) {
            for off in tiff.ints(se, limit: 8) {
                if let (sub, _) = tiff.readIFD(atOffset: off), let r = previewRange(tiff, sub) { previews.append(r) }
            }
        }
        // ファイルの大きさが分かるときは、ファイル内に収まる候補だけから最大を選ぶ
        if let fileSize { previews = previews.filter { $0.fits(inFileOfSize: fileSize) } }
        m.mpfPreview = previews.max { $0.length < $1.length }
        // 幅・高さは IFD0 が RAW 本体でないことがあるので、ExifIFD の値だけを使う

        guard let pe = ifd0.entry(0x8769), let exifOff = tiff.firstInt(pe),
              let (exif, _) = tiff.readIFD(atOffset: exifOff) else { return m }

        if let e = exif.entry(0xA002), let w = tiff.firstInt(e) { m.imageWidth = w }
        if let e = exif.entry(0xA003), let h = tiff.firstInt(e) { m.imageHeight = h }

        if let e = exif.entry(0x9003), let s = tiff.string(e) {
            let sub = exif.entry(0x9291).flatMap { tiff.string($0) }
            let offset = exif.entry(0x9011).flatMap { tiff.string($0) }
            m.captureDate = JPEGMetadataReader.parseDate(s, subSec: sub, offset: offset)
        }

        if let e = exif.entry(0x927C),
           let v = SonyMakerNote.parse(tiff: tiff, start: e.valueIndex, length: e.count) {
            m.releaseMode = v.releaseMode
            m.sequenceNumber = v.sequenceNumber
            m.focusLocation = v.focusLocation
            m.focusFrameSize = v.focusFrameSize
        }
        return m
    }

    /// JpgFromRawStart（0x0201）/ JpgFromRawLength（0x0202）から範囲を作る。
    /// 先頭が JPEG（FF D8）であることまでは確認できないので、値が正のときだけ返す。
    private static func previewRange(_ tiff: TIFFReader, _ entries: [IFDEntry]) -> FileRange? {
        guard let oe = entries.entry(0x0201), let le = entries.entry(0x0202),
              let off = tiff.firstInt(oe), let len = tiff.firstInt(le), off > 0, len > 0 else { return nil }
        return FileRange(offset: off, length: len)
    }
}

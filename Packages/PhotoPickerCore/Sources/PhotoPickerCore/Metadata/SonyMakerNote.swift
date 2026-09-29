import Foundation

/// Sony MakerNote から取り出す値
struct SonyMakerNoteValues: Sendable, Equatable {
    var releaseMode: Int?
    var sequenceNumber: Int?
    var focusLocation: FocusLocation?
    var focusFrameSize: FocusFrameSize?
}

enum SonyMakerNote {
    /// `"SONY DSC \0\0\0"`（12 バイト）
    private static let header: [UInt8] = Array("SONY DSC ".utf8) + [0, 0, 0]

    /// JPG の MakerNote は `"SONY DSC "` ヘッダーの後に IFD が続く。ARW（α1 II で確認）はヘッダーが無く、先頭がすぐ IFD
    /// （exiftool の MakerNoteSony5）。どちらも値のオフセットは TIFF ヘッダー基準。
    /// - Parameters:
    ///   - tiff: MakerNote を含む Exif の TIFF リーダー（オフセットの基準になる）
    ///   - start: MakerNote データの先頭の絶対添字
    ///   - length: MakerNote データの長さ
    static func parse(tiff: TIFFReader, start: Int, length: Int) -> SonyMakerNoteValues? {
        guard let ifd = ifdStart(tiff: tiff, start: start, length: length),
              let (entries, _) = tiff.readIFD(atAbsolute: ifd) else { return nil }

        var v = SonyMakerNoteValues()
        if let e = entries.entry(0xB049) { v.releaseMode = tiff.firstInt(e) }
        if let e = entries.entry(0xB04A) { v.sequenceNumber = tiff.firstInt(e) }
        if let e = entries.entry(0x2027) {
            let a = rawUInt16s(tiff, e, count: 4)
            if a.count == 4 { v.focusLocation = FocusLocation(width: a[0], height: a[1], x: a[2], y: a[3]) }
        }
        if let e = entries.entry(0x2037) {
            let a = rawUInt16s(tiff, e, count: 3)
            if a.count == 3 { v.focusFrameSize = FocusFrameSize(width: a[0], height: a[1], flag: a[2]) }
        }
        return v
    }

    /// 値が 4 バイトを超え、IFD の外に置かれるタグ（FocusLocation・FocusFrameSize）
    static let outOfLineTags: Set<Int> = [0x2027, 0x2037]

    /// MakerNote の IFD の絶対添字。ヘッダーがあればその直後、無ければ先頭。
    /// ヘッダーが無いときは、エントリ数が MakerNote の長さに収まることだけ確かめる。
    static func ifdStart(tiff: TIFFReader, start: Int, length: Int) -> Int? {
        guard length > 2, start >= 0, start + 2 <= tiff.data.count else { return nil }
        let hasHeader = length > header.count && start + header.count <= tiff.data.count
            && header.indices.allSatisfy { tiff.data[start + $0] == header[$0] }
        if hasHeader { return start + header.count }
        guard let n = tiff.u16(start), n > 0, 2 + n * 12 <= length else { return nil }
        return start
    }

    /// 型宣言（byte / undefined のことがある）にかかわらず、値領域を u16 の並びとして読む
    private static func rawUInt16s(_ tiff: TIFFReader, _ e: IFDEntry, count: Int) -> [Int] {
        // 宣言サイズ（型 × 個数）が必要バイト数に満たないときは読まない
        guard TIFFReader.typeSize(e.type) * e.count >= count * 2 else { return [] }
        var out: [Int] = []
        for k in 0..<count {
            guard let v = tiff.u16(e.valueIndex + k * 2) else { return [] }
            out.append(v)
        }
        return out
    }
}

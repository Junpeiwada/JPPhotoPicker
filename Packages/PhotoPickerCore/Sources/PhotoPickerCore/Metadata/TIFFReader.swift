import Foundation

/// IFD エントリ 1 件（値の実体位置はバッファ内の絶対添字）
struct IFDEntry: Sendable {
    let tag: Int
    let type: Int
    let count: Int
    /// 値の実体が始まるバッファ内の添字
    let valueIndex: Int
}

/// TIFF 構造（Exif / MakerNote / MPF 共通）を `[UInt8]` から読む。
/// 値のオフセットは TIFF ヘッダー位置（`base`）基準。
struct TIFFReader: Sendable {
    let data: [UInt8]
    let base: Int
    let littleEndian: Bool

    init?(data: [UInt8], base: Int) {
        guard base >= 0, base + 8 <= data.count else { return nil }
        let a = data[base], b = data[base + 1]
        if a == 0x49 && b == 0x49 {
            littleEndian = true
        } else if a == 0x4D && b == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        self.data = data
        self.base = base
        guard u16(base + 2) == 42 else { return nil }
    }

    func u16(_ i: Int) -> Int? {
        guard i >= 0, i + 2 <= data.count else { return nil }
        let x = Int(data[i]), y = Int(data[i + 1])
        return littleEndian ? (y << 8 | x) : (x << 8 | y)
    }

    func u32(_ i: Int) -> Int? {
        guard i >= 0, i + 4 <= data.count else { return nil }
        let b0 = Int(data[i]), b1 = Int(data[i + 1]), b2 = Int(data[i + 2]), b3 = Int(data[i + 3])
        return littleEndian
            ? (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }

    /// IFD0 の位置（TIFF ヘッダー基準のオフセット）
    var firstIFDOffset: Int? { u32(base + 4) }

    static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    /// 絶対添字 `ifd` にある IFD を読む。値の範囲がバッファ外のエントリは除く。
    /// - Returns: エントリ一覧と、次の IFD への絶対添字（無ければ nil）
    func readIFD(atAbsolute ifd: Int) -> (entries: [IFDEntry], next: Int?)? {
        guard let n = u16(ifd), n < 2000 else { return nil }
        var result: [IFDEntry] = []
        result.reserveCapacity(n)
        for k in 0..<n {
            let pos = ifd + 2 + k * 12
            guard let tag = u16(pos), let type = u16(pos + 2), let count = u32(pos + 4) else { return nil }
            let bytes = Self.typeSize(type) * count
            guard bytes >= 0, Self.typeSize(type) > 0 else { continue }
            let valueIndex: Int
            if bytes <= 4 {
                valueIndex = pos + 8
            } else {
                guard let off = u32(pos + 8) else { continue }
                valueIndex = base + off
            }
            guard valueIndex >= 0, valueIndex + bytes <= data.count else { continue }
            result.append(IFDEntry(tag: tag, type: type, count: count, valueIndex: valueIndex))
        }
        var next: Int?
        if let nextOff = u32(ifd + 2 + n * 12), nextOff != 0 {
            next = base + nextOff
        }
        return (result, next)
    }

    /// TIFF ヘッダー基準のオフセットで IFD を読む
    func readIFD(atOffset off: Int) -> (entries: [IFDEntry], next: Int?)? {
        readIFD(atAbsolute: base + off)
    }

    /// 整数値（byte / short / long / signed）を最大 `limit` 個読む
    func ints(_ e: IFDEntry, limit: Int = 64) -> [Int] {
        let n = min(e.count, limit)
        var out: [Int] = []
        out.reserveCapacity(n)
        for k in 0..<n {
            switch e.type {
            case 1, 7:
                out.append(Int(data[e.valueIndex + k]))
            case 3:
                guard let v = u16(e.valueIndex + k * 2) else { return out }
                out.append(v)
            case 8:
                guard let v = u16(e.valueIndex + k * 2) else { return out }
                out.append(v >= 0x8000 ? v - 0x10000 : v)
            case 4, 13:   // 13 = IFD（u32 のオフセット）
                guard let v = u32(e.valueIndex + k * 4) else { return out }
                out.append(v)
            case 9:
                guard let v = u32(e.valueIndex + k * 4) else { return out }
                out.append(v >= 0x8000_0000 ? v - 0x1_0000_0000 : v)
            default:
                return out
            }
        }
        return out
    }

    func firstInt(_ e: IFDEntry) -> Int? { ints(e, limit: 1).first }

    /// ASCII 文字列（NUL・末尾の空白で切る）
    func string(_ e: IFDEntry) -> String? {
        guard e.type == 2 || e.type == 7 else { return nil }
        let slice = data[e.valueIndex ..< e.valueIndex + e.count]
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

extension Array where Element == IFDEntry {
    func entry(_ tag: Int) -> IFDEntry? { first { $0.tag == tag } }
}

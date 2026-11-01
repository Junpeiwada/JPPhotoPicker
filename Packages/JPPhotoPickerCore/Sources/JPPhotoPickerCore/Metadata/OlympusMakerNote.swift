import Foundation

/// Olympus `AFPointSelected`（CameraSettings 0x0305）の AF の点（センサー向き）。
/// TG-6 では 640×480 の格子（分母 640 / 480）で記録され、4:3 の全センサーに対する比率になっている。
/// 3:2 などに切り出した画像では、この座標系の中央を切り出したものが画像になる（ORF の `AspectFrame` で確認）
public struct OlympusAFPoint: Sendable, Equatable, Hashable {
    /// 座標系に対する比率（0〜1）
    public let x: Double
    public let y: Double
    /// 座標系の縦横比（幅 ÷ 高さ。分母の比から求める。TG-6 は 640 / 480 = 4:3）
    public let frameAspect: Double

    public init(x: Double, y: Double, frameAspect: Double) {
        self.x = x
        self.y = y
        self.frameAspect = frameAspect
    }
}

/// Olympus MakerNote から取り出す値
struct OlympusMakerNoteValues: Sendable, Equatable {
    var afPoint: OlympusAFPoint?
    /// 埋め込みプレビュー（JPEG）のファイル内位置。ORF では全センサー 4:3 のまま（3200×2400）
    var preview: FileRange?
    /// `AspectFrame`（ImageProcessing 0x1113）: 切り出す範囲の左・上・右・下（端を含む画素座標）
    var aspectFrame: [Int]?

    /// `aspectFrame` から求めた画像の幅・高さ
    var aspectFrameSize: (width: Int, height: Int)? {
        guard let f = aspectFrame, f.count == 4 else { return nil }
        let w = f[2] - f[0] + 1, h = f[3] - f[1] + 1
        return w > 0 && h > 0 ? (w, h) : nil
    }
}

/// Olympus / OM SYSTEM の MakerNote（exiftool の Olympus2 / OMSystem 形式）。
/// `"OLYMPUS\0" + "II" + 3`（12 バイト）または `"OM SYSTEM\0\0\0" + "II" + 4`（16 バイト）のヘッダーの後に IFD が続く。
/// 値のオフセットは MakerNote の先頭基準。必要な値はサブ IFD（CameraSettings 0x2020・ImageProcessing 0x2040）にある。
/// 実機で確認したのは TG-6（OLYMPUS 形式）だけ。
enum OlympusMakerNote {
    private static let olympusHeader: [UInt8] = Array("OLYMPUS".utf8) + [0]
    private static let omSystemHeader: [UInt8] = Array("OM SYSTEM".utf8) + [0, 0, 0]

    static let cameraSettingsTag = 0x2020
    static let imageProcessingTag = 0x2040

    /// MakerNote 用の TIFF リーダー（基準 = MakerNote の先頭）と、メイン IFD の絶対添字。Olympus 形式でなければ nil
    static func reader(data: [UInt8], start: Int) -> (tiff: TIFFReader, ifd: Int)? {
        func matches(_ h: [UInt8]) -> Bool {
            start >= 0 && start + h.count + 4 <= data.count && h.indices.allSatisfy { data[start + $0] == h[$0] }
        }
        let headerLength: Int
        if matches(olympusHeader) {
            headerLength = 12
        } else if matches(omSystemHeader) {
            headerLength = 16
        } else {
            return nil
        }
        let order = start + headerLength - 4
        let little: Bool
        switch (data[order], data[order + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        return (TIFFReader(data: data, base: start, littleEndian: little), start + headerLength)
    }

    /// MakerNote の先頭 `start`（絶対添字）から値を読む。Olympus 形式でなければ nil
    static func parse(data: [UInt8], start: Int) -> OlympusMakerNoteValues? {
        guard let (tiff, ifd) = reader(data: data, start: start),
              let (main, _) = tiff.readIFD(atAbsolute: ifd) else { return nil }

        var v = OlympusMakerNoteValues()
        if let cs = subIFD(tiff, main, tag: cameraSettingsTag), let (entries, _) = tiff.readIFD(atAbsolute: cs) {
            if let e = entries.entry(0x0305) { v.afPoint = afPoint(tiff.rationals(e, limit: 5)) }
            if let valid = entries.entry(0x0100).flatMap(tiff.firstInt), valid != 0,
               let off = entries.entry(0x0101).flatMap(tiff.firstInt),
               let len = entries.entry(0x0102).flatMap(tiff.firstInt), off > 0, len > 0 {
                v.preview = FileRange(offset: start + off, length: len)
            }
        }
        if let ip = subIFD(tiff, main, tag: imageProcessingTag), let (entries, _) = tiff.readIFD(atAbsolute: ip),
           let e = entries.entry(0x1113) {
            let a = tiff.ints(e, limit: 4)
            if a.count == 4 { v.aspectFrame = a }
        }
        return v
    }

    /// 値を読むのに必要なバイト数（先頭から）。サブ IFD の位置がまだ読めないときは、MakerNote の先頭から 64KB を見込む
    static func neededEnd(data: [UInt8], start: Int) -> Int {
        let fallback = start + 64 * 1024
        guard let (tiff, ifd) = reader(data: data, start: start),
              var end = tiff.neededEnd(ofIFDAtAbsolute: ifd, tags: []),
              let (main, _) = tiff.readIFD(atAbsolute: ifd) else { return fallback }
        for (tag, values) in [(cameraSettingsTag, Set([0x0305])), (imageProcessingTag, Set([0x1113]))] {
            guard let sub = subIFD(tiff, main, tag: tag) else { continue }
            guard let e = tiff.neededEnd(ofIFDAtAbsolute: sub, tags: values) else { return max(end, sub + 64 * 1024) }
            end = max(end, e)
        }
        return end
    }

    /// サブ IFD の絶対添字。型が IFD / long ならオフセット（MakerNote 先頭基準）、undefined なら値の位置にそのまま IFD がある
    private static func subIFD(_ tiff: TIFFReader, _ entries: [IFDEntry], tag: Int) -> Int? {
        guard let e = entries.entry(tag) else { return nil }
        if e.type == 7 { return e.valueIndex }
        return tiff.firstInt(e).map { tiff.base + $0 }
    }

    /// AFPointSelected: 1 番目は未使用、残り 4 つが (x, y) (x, y)。2 点の中点を AF の点とする。
    /// 分母が 0（n/a）のときや範囲外のときは nil
    private static func afPoint(_ r: [(num: Int, den: Int)]) -> OlympusAFPoint? {
        guard r.count == 5, r[1...].allSatisfy({ $0.den > 0 }) else { return nil }
        let v = r[1...].map { Double($0.num) / Double($0.den) }
        guard v.allSatisfy({ (0...1).contains($0) }) else { return nil }
        // 分母が x・y で同じなら座標系の形が分からないので、Olympus のセンサーの 4:3 とみなす
        let aspect = r[1].den != r[2].den ? Double(r[1].den) / Double(r[2].den) : 4.0 / 3.0
        return OlympusAFPoint(x: (v[0] + v[2]) / 2, y: (v[1] + v[3]) / 2, frameAspect: aspect)
    }
}

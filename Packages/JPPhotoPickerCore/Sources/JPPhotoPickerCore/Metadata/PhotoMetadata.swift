import Foundation
import CoreGraphics

/// ファイル内のバイト範囲（先頭からのオフセットと長さ）
public struct FileRange: Sendable, Equatable, Hashable, Codable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    /// この範囲が、大きさ `fileSize` のファイルの中に収まっているか
    public func fits(inFileOfSize fileSize: Int) -> Bool {
        offset >= 0 && length > 0 && offset <= fileSize && length <= fileSize - offset
    }

    /// `url` のこの範囲だけを読む（サムネイル・MPF プレビューの取り出し用）
    public func readData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// Sony `FocusLocation`（0x2027）: 画像の幅・高さ・X・Y（ピクセル、センサー向き）
public struct FocusLocation: Sendable, Equatable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public let x: Int
    public let y: Int

    public init(width: Int, height: Int, x: Int, y: Int) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

/// Sony `FocusFrameSize`（0x2037）: 枠の幅・高さ・有効フラグ（257 = 有効、0 = 無効）
public struct FocusFrameSize: Sendable, Equatable, Hashable, Codable {
    public let width: Int
    public let height: Int
    public let flag: Int

    public init(width: Int, height: Int, flag: Int) {
        self.width = width
        self.height = height
        self.flag = flag
    }

    public var isValid: Bool { flag != 0 }
}

/// 1 枚の写真から読み取ったメタデータ
public struct PhotoMetadata: Sendable, Equatable, Hashable {
    /// 撮影日時（DateTimeOriginal + SubSec + OffsetTime）。無ければ nil
    public var captureDate: Date?
    /// EXIF Orientation（1〜8）。無ければ 1
    public var orientation: Int
    /// Sony ReleaseMode（0 = 単写、2 = 連写 など）
    public var releaseMode: Int?
    /// Sony SequenceNumber（0 = 単写、1 以上 = 連写の何枚目か）
    public var sequenceNumber: Int?
    public var focusLocation: FocusLocation?
    public var focusFrameSize: FocusFrameSize?
    /// IFD1 サムネイル（JPEG）のファイル内位置
    public var thumbnail: FileRange?
    /// MPF 2 枚目（プレビュー、1920×1080 程度）のファイル内位置
    public var mpfPreview: FileRange?
    public var imageWidth: Int?
    public var imageHeight: Int?

    public init(
        captureDate: Date? = nil,
        orientation: Int = 1,
        releaseMode: Int? = nil,
        sequenceNumber: Int? = nil,
        focusLocation: FocusLocation? = nil,
        focusFrameSize: FocusFrameSize? = nil,
        thumbnail: FileRange? = nil,
        mpfPreview: FileRange? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.captureDate = captureDate
        self.orientation = orientation
        self.releaseMode = releaseMode
        self.sequenceNumber = sequenceNumber
        self.focusLocation = focusLocation
        self.focusFrameSize = focusFrameSize
        self.thumbnail = thumbnail
        self.mpfPreview = mpfPreview
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// 表示向き（Orientation を当てた後）の画素サイズ。Orientation 5〜8（90° 回転を含む）は縦横を入れ替える。
    /// 画像サイズが無い・0 以下なら nil
    public var displayPixelSize: CGSize? {
        guard let w = imageWidth, let h = imageHeight, w > 0, h > 0 else { return nil }
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// 連写のコマか（ReleaseMode == 2 かつ SequenceNumber >= 1）
    public var isBurstFrame: Bool {
        releaseMode == 2 && (sequenceNumber ?? 0) >= 1
    }
}

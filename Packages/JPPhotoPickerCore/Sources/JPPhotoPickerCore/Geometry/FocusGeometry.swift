import Foundation

public struct NormalizedPoint: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NormalizedSize: Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 表示向きの正規化座標（0〜1）にしたフォーカス位置と枠
public struct FocusGeometry: Sendable, Equatable, Hashable {
    /// 表示向きの中心（0〜1）。フォーカス位置なしのときは (0.5, 0.5)
    public let center: NormalizedPoint
    /// 表示向きの枠の大きさ（画像の幅・高さに対する比率）。枠なしのときは nil
    public let frameSize: NormalizedSize?
    /// カメラのフォーカス位置（Sony の FocusLocation / Olympus の AFPointSelected）が使えるか。false のときは中心・枠なし
    public let hasFocusPosition: Bool

    public init(center: NormalizedPoint, frameSize: NormalizedSize?, hasFocusPosition: Bool) {
        self.center = center
        self.frameSize = frameSize
        self.hasFocusPosition = hasFocusPosition
    }

    /// フォーカス位置なし（中心・枠なし）
    public static let centered = FocusGeometry(
        center: NormalizedPoint(x: 0.5, y: 0.5), frameSize: nil, hasFocusPosition: false)

    public init(metadata: PhotoMetadata) {
        if metadata.focusLocation == nil, let point = metadata.olympusAFPoint {
            self.init(olympus: point, imageWidth: metadata.imageWidth, imageHeight: metadata.imageHeight,
                      orientation: metadata.orientation)
            return
        }
        self.init(location: metadata.focusLocation,
                  frameSize: metadata.focusFrameSize,
                  orientation: metadata.orientation)
    }

    /// Olympus の AF の枠の一辺（画像の短辺に対する比率）。枠の大きさは記録されていないので固定にする
    public static let olympusFrameRatio = 0.06

    /// Olympus の AF の点から作る。座標系（TG-6 は 4:3 の全センサー）の中央を、画像の縦横比
    /// （`imageWidth` ÷ `imageHeight`、センサー向き）で切り出したものとして換算する。
    /// 画像の大きさが無いときは座標系と同じ形とみなす。切り出しの外に出る点は、位置なしとして扱う。
    public init(olympus point: OlympusAFPoint, imageWidth: Int?, imageHeight: Int?, orientation: Int) {
        var x = point.x, y = point.y
        var aspect = point.frameAspect
        if let w = imageWidth, let h = imageHeight, w > 0, h > 0 {
            aspect = Double(w) / Double(h)
            if aspect > point.frameAspect {
                // 横長に切り出した（上下を切った）: 残った高さの割合
                let f = point.frameAspect / aspect
                y = (y - (1 - f) / 2) / f
            } else if aspect < point.frameAspect {
                let f = aspect / point.frameAspect
                x = (x - (1 - f) / 2) / f
            }
        }
        guard aspect > 0, (0...1).contains(x), (0...1).contains(y) else {
            self = .centered
            return
        }
        let center = Self.transform(NormalizedPoint(x: x, y: y), orientation: orientation)
        // 短辺に対して一定の大きさの正方形（センサー向きで、短辺 = 高さ（横長）または幅（縦長））
        var w = aspect >= 1 ? Self.olympusFrameRatio / aspect : Self.olympusFrameRatio
        var h = aspect >= 1 ? Self.olympusFrameRatio : Self.olympusFrameRatio * aspect
        if (5...8).contains(orientation) { swap(&w, &h) }
        self.init(center: center, frameSize: NormalizedSize(width: w, height: h), hasFocusPosition: true)
    }

    public init(location: FocusLocation?, frameSize: FocusFrameSize?, orientation: Int) {
        guard let location, location.width > 0, location.height > 0,
              frameSize?.isValid ?? true else {
            self = .centered
            return
        }
        let raw = NormalizedPoint(
            x: Self.clamp(Double(location.x) / Double(location.width)),
            y: Self.clamp(Double(location.y) / Double(location.height)))
        let center = Self.transform(raw, orientation: orientation)

        var size: NormalizedSize?
        if let frameSize, frameSize.isValid {
            var w = Double(frameSize.width) / Double(location.width)
            var h = Double(frameSize.height) / Double(location.height)
            if (5...8).contains(orientation) { swap(&w, &h) }
            size = NormalizedSize(width: min(w, 1), height: min(h, 1))
        }
        self.init(center: center, frameSize: size, hasFocusPosition: true)
    }

    /// 保存画素（センサー）向きの正規化座標を、EXIF Orientation に従って表示向きへ変換する。
    public static func transform(_ p: NormalizedPoint, orientation: Int) -> NormalizedPoint {
        let x = p.x, y = p.y
        switch orientation {
        case 2: return NormalizedPoint(x: 1 - x, y: y)          // 左右反転
        case 3: return NormalizedPoint(x: 1 - x, y: 1 - y)      // 180 度回転
        case 4: return NormalizedPoint(x: x, y: 1 - y)          // 上下反転
        case 5: return NormalizedPoint(x: y, y: x)              // 転置
        case 6: return NormalizedPoint(x: 1 - y, y: x)          // 時計回り 90 度
        case 7: return NormalizedPoint(x: 1 - y, y: 1 - x)      // 反転転置
        case 8: return NormalizedPoint(x: y, y: 1 - x)          // 反時計回り 90 度
        default: return p
        }
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

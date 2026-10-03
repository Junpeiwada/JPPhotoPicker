import Foundation
import CoreGraphics

/// ズーム操作に必要な、ビューと画像の大きさ。
public struct ZoomViewport: Sendable, Equatable {
    public let viewSize: CGSize
    /// 表示向きの本体画像の大きさ（画素）
    public let imagePixelSize: CGSize
    /// 1 ポイントあたりの物理ピクセル数（Retina は 2）
    public let backingScale: Double
    /// 全体表示のときだけ、ビューの上端から空ける高さ（ツールバーの下に写真が隠れないようにする）。
    /// 拡大中はビュー全体を使う（ツールバーの下まで描いてよい）。
    public let fitTopInset: CGFloat

    public init(viewSize: CGSize, imagePixelSize: CGSize, backingScale: Double, fitTopInset: CGFloat = 0) {
        self.viewSize = viewSize
        self.imagePixelSize = imagePixelSize
        self.backingScale = backingScale > 0 ? backingScale : 1
        self.fitTopInset = max(fitTopInset, 0)
    }

    /// 全体表示に使える高さ（ポイント）
    var fitHeight: Double { Double(viewSize.height) - Double(fitTopInset) }

    public var isValid: Bool {
        viewSize.width > 0 && viewSize.height > 0 && fitHeight > 0
            && imagePixelSize.width > 0 && imagePixelSize.height > 0
    }

    /// 全体表示の倍率（物理ピクセル基準）。大きさが無効なら 1。上端の空き（`fitTopInset`）を除いた領域に収める。
    public var fitScale: Double {
        guard isValid else { return 1 }
        return min(Double(viewSize.width) * backingScale / Double(imagePixelSize.width),
                   fitHeight * backingScale / Double(imagePixelSize.height))
    }

    /// 倍率 `scale` で表示したときの「ビューの大きさ ÷ 画像の表示サイズ」（軸ごと）
    public func viewFraction(scale: Double) -> NormalizedSize {
        guard isValid, scale > 0 else { return NormalizedSize(width: 1, height: 1) }
        let ppp = scale / backingScale
        return NormalizedSize(width: Double(viewSize.width) / (Double(imagePixelSize.width) * ppp),
                              height: Double(viewSize.height) / (Double(imagePixelSize.height) * ppp))
    }

    /// 倍率 `scale` で画像の外を見せない範囲に中心を収める（画像がビューに収まる軸は 0.5）
    public func clamp(center: NormalizedPoint, scale: Double) -> NormalizedPoint {
        let f = viewFraction(scale: scale)
        func axis(_ v: Double, _ fr: Double) -> Double {
            if fr >= 1 { return 0.5 }
            return min(max(v, fr / 2), 1 - fr / 2)
        }
        return NormalizedPoint(x: axis(center.x, f.width), y: axis(center.y, f.height))
    }
}

/// ビュー（ポイント）と表示向きの画像（画素）と `ZoomState` から、画像を描く位置を求める。
/// 座標は左上原点・y 下向き。
public struct ViewportGeometry: Sendable, Equatable {
    public let viewSize: CGSize
    /// 表示向きの本体画像の大きさ（画素）
    public let imagePixelSize: CGSize
    /// 1 ポイントあたりの物理ピクセル数（Retina は 2）
    public let backingScale: Double
    public let zoom: ZoomState
    /// 全体表示のときの上端の空き（`ZoomViewport.fitTopInset`）
    public let topInset: CGFloat

    public init(viewSize: CGSize, imagePixelSize: CGSize, backingScale: Double, zoom: ZoomState, topInset: CGFloat = 0) {
        self.viewSize = viewSize
        self.imagePixelSize = imagePixelSize
        self.backingScale = backingScale > 0 ? backingScale : 1
        self.zoom = zoom
        self.topInset = max(topInset, 0)
    }

    /// `ZoomState` の操作に渡す、ビューと画像の大きさ
    public var viewport: ZoomViewport {
        ZoomViewport(viewSize: viewSize, imagePixelSize: imagePixelSize, backingScale: backingScale, fitTopInset: topInset)
    }

    public var isValid: Bool { viewport.isValid }

    /// 全体表示の倍率（物理ピクセル基準）
    public var fitScale: Double { viewport.fitScale }

    /// 今の倍率（物理ピクセル基準）
    public var effectiveScale: Double { zoom.scale ?? fitScale }

    /// 画像の表示サイズ（ポイント）
    public var displaySize: CGSize {
        let ppp = effectiveScale / backingScale
        return CGSize(width: Double(imagePixelSize.width) * ppp, height: Double(imagePixelSize.height) * ppp)
    }

    /// ビューの大きさ ÷ 表示サイズ（軸ごと）
    public var viewFraction: NormalizedSize {
        let d = displaySize
        guard d.width > 0, d.height > 0 else { return NormalizedSize(width: 1, height: 1) }
        return NormalizedSize(width: Double(viewSize.width / d.width), height: Double(viewSize.height / d.height))
    }

    /// 端のクランプ後の中心
    public var clampedCenter: NormalizedPoint {
        guard let s = zoom.scale, viewport.isValid else { return zoom.center }
        return viewport.clamp(center: zoom.center, scale: s)
    }

    /// 画像が描かれる矩形（ポイント）。画像がビューより小さい軸は中央に置き、大きい軸は端を超えないようにする。
    /// 全体表示のときは上端の空き（`topInset`）を除いた領域の中央、拡大中はビュー全体の中央が中心。
    public var imageRect: CGRect {
        guard isValid else { return .zero }
        let d = displaySize
        let c = clampedCenter
        let centerY = zoom.isFit
            ? Double(topInset) + viewport.fitHeight / 2
            : Double(viewSize.height) / 2
        let origin = CGPoint(x: Double(viewSize.width) / 2 - c.x * Double(d.width),
                             y: centerY - c.y * Double(d.height))
        return CGRect(origin: origin, size: d)
    }

    /// ビュー上の点 → 画像の正規化座標（0〜1 にクランプ）
    public func normalizedPoint(forViewPoint p: CGPoint) -> NormalizedPoint {
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return NormalizedPoint(x: 0.5, y: 0.5) }
        return NormalizedPoint(x: min(max(Double((p.x - r.minX) / r.width), 0), 1),
                               y: min(max(Double((p.y - r.minY) / r.height), 0), 1))
    }

    /// 画像の正規化座標 → ビュー上の点
    public func viewPoint(forNormalized n: NormalizedPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height)
    }
}

import Foundation

/// 拡大表示の状態と操作ルール（純粋ロジック）。
///
/// - 倍率は「画像 1 画素 = 画面の物理 1 ピクセル」を 1.0（100%）とする。
/// - 中心は表示向きの画像に対する正規化座標（0〜1）。
/// - 全体表示（fit）の倍率・中心のクランプはビューと画像の大きさで決まるため、操作は `ZoomViewport` を引数で受ける。
/// - `center` は常にクランプ済み（拡大中は画像の外を見せない範囲）。
public struct ZoomState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// 全体表示（ウインドウに収める）
        case fit
        /// 倍率固定（1.0 = 100%）
        case scale(Double)
    }

    /// Z で進む段階（100%、200%）
    public static let stages: [Double] = [1.0, 2.0]
    /// 最大倍率
    public static let maxScale: Double = 2.0

    public private(set) var mode: Mode
    /// 表示中心（表示向きの正規化座標）。全体表示のときは (0.5, 0.5)
    public private(set) var center: NormalizedPoint

    public init(mode: Mode = .fit, center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5)) {
        self.mode = mode
        self.center = mode == .fit ? NormalizedPoint(x: 0.5, y: 0.5) : center
    }

    public var isFit: Bool { mode == .fit }

    /// 拡大中の倍率。全体表示なら nil
    public var scale: Double? {
        if case .scale(let s) = mode { return s }
        return nil
    }

    private static let epsilon = 0.001

    // MARK: 操作
    //
    // 中心を動かす操作はすべて `ZoomViewport`（ビューの大きさ・画像の画素サイズ・backingScale）を受け取り、
    // 状態の `center` を常に「画像の外を見せない範囲」にクランプした値で持つ。

    /// Z キー。全体表示ならフォーカス位置を最初の段階（100%）に。拡大中は次に大きい段階へ（クランプ済みの中心を保つ）、
    /// 最大段階以上なら全体表示へ。全体表示の倍率が段階以上（小さな画像）なら、その段階は飛ばす。
    public mutating func pressZ(focus: NormalizedPoint, viewport: ZoomViewport) {
        let fit = viewport.fitScale
        let current = scale ?? fit
        if let next = Self.stages.first(where: { $0 > max(current, fit) + Self.epsilon }) {
            let wasFit = isFit
            mode = .scale(next)
            if wasFit { center = Self.clamp01(focus) }
            clampCenter(viewport: viewport)
        } else {
            reset()
        }
    }

    /// Esc キー。全体表示に戻す。
    public mutating func escape() { reset() }

    /// プレビューのクリック。全体表示ならその点（画像の正規化座標）を、全体表示の倍率より大きい最初の段階
    /// （通常 100%。全体表示の倍率が 100% を超える画像では 200%）で拡大する。拡大中は全体表示へ。
    /// 全体表示の倍率が最大段階以上（小さな画像）なら、拡大の段階が無いので全体表示のまま。
    public mutating func click(at point: NormalizedPoint, viewport: ZoomViewport) {
        if isFit {
            guard let first = Self.stages.first(where: { $0 > viewport.fitScale + Self.epsilon }) else { return }
            mode = .scale(first)
            center = Self.clamp01(point)
            clampCenter(viewport: viewport)
        } else {
            reset()
        }
    }

    /// ピンチ。全体表示〜200% にクランプする。指の下の画素が動かないよう中心を補正する。
    ///
    /// - Parameters:
    ///   - scale: 変更後の**絶対倍率**（物理ピクセル基準）。ジェスチャー開始時の倍率 × 累積倍率
    ///     （`pinchTarget(startScale:magnification:)`）を渡すこと。1 イベントの変化が小さくても、
    ///     累積が全体表示のしきい値（fit × 1.01）を超えた時点で拡大が始まる。
    ///   - anchor: 指の間の点の **画像上の正規化座標**（今の表示で指の下にある画素。
    ///     `ViewportGeometry.normalizedPoint(forViewPoint:)` の値）。ビュー上の位置ではない。
    ///   - viewport: 今のビュー・画像の大きさ
    ///
    /// 補正式: `k = 旧倍率 / 新倍率`、`center = anchor + (center − anchor) × k`
    /// （全体表示から始めるときは 旧倍率 = fitScale、center = (0.5, 0.5)）。その後、端をクランプする。
    public mutating func pinch(to scale: Double, anchor: NormalizedPoint, viewport: ZoomViewport) {
        let fitScale = viewport.fitScale
        guard scale.isFinite, scale > 0 else { return }
        let upper = max(Self.maxScale, fitScale)
        let s = min(scale, upper)
        if s <= fitScale * 1.01 {
            reset()
            return
        }
        let old = self.scale ?? fitScale
        let oldCenter = isFit ? NormalizedPoint(x: 0.5, y: 0.5) : center
        let a = Self.clamp01(anchor)
        let k = old / s
        center = Self.clamp01(NormalizedPoint(x: a.x + (oldCenter.x - a.x) * k,
                                              y: a.y + (oldCenter.y - a.y) * k))
        mode = .scale(s)
        clampCenter(viewport: viewport)
    }

    /// ジェスチャー開始時の倍率と累積倍率から、`pinch` に渡す絶対倍率を作る。
    public static func pinchTarget(startScale: Double, magnification: Double) -> Double {
        startScale * magnification
    }

    /// 表示位置を動かす（正規化座標の差分）。全体表示では何もしない。結果はクランプされる。
    public mutating func pan(dx: Double, dy: Double, viewport: ZoomViewport) {
        guard !isFit else { return }
        center = Self.clamp01(NormalizedPoint(x: center.x + dx, y: center.y + dy))
        clampCenter(viewport: viewport)
    }

    /// F / [フォーカス位置へ]。全体表示なら Z と同じ。拡大中は倍率を保って中心だけ移す。
    public mutating func moveToFocus(focus: NormalizedPoint, viewport: ZoomViewport) {
        if isFit {
            pressZ(focus: focus, viewport: viewport)
        } else {
            center = Self.clamp01(focus)
            clampCenter(viewport: viewport)
        }
    }

    /// コマを移ったとき。`viewport` は移り先のコマの画像のもの。
    /// 同じグループなら位置・倍率を保つ。別グループなら倍率を保って移り先のフォーカス位置へ。
    /// 拡大中は、どちらの場合も移り先の大きさでクランプし直す。
    /// 移り先の全体表示倍率以下の倍率になってしまう（小さな画像など）ときは、拡大の意味が無いので全体表示に戻す。
    public mutating func didMoveToItem(sameGroup: Bool, focus: NormalizedPoint, viewport: ZoomViewport) {
        guard let s = scale else { return }
        if viewport.isValid, s <= viewport.fitScale + Self.epsilon {
            reset()
            return
        }
        if !sameGroup { center = Self.clamp01(focus) }
        clampCenter(viewport: viewport)
    }

    /// 表示端のクランプ（`ZoomViewport.clamp` に一本化）。ビューや画像の大きさが変わったときに呼ぶ。全体表示では何もしない。
    public mutating func clampCenter(viewport: ZoomViewport) {
        guard let s = scale, viewport.isValid else { return }
        center = viewport.clamp(center: center, scale: s)
    }

    // MARK: 内部

    private mutating func reset() {
        mode = .fit
        center = NormalizedPoint(x: 0.5, y: 0.5)
    }

    private static func clamp01(_ p: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}

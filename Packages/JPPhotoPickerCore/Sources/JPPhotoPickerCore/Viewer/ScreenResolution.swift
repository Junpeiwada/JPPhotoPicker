import CoreGraphics

/// 全体表示用の画像（本体の縮小）を何画素で作るか。
public enum ScreenResolution {
    /// 刻み（ウインドウを少し動かすたびにデコードし直さないよう、この単位で切り上げる）
    public static let step = 256

    /// 全体表示の領域（ビューからツールバーの高さを引いた範囲）の長辺を物理ピクセルにして、`step` 単位で切り上げる。
    /// 写真の縦横比によらず、全体表示の写真の長辺はこれを超えない。領域が無いときは 0。
    public static func maxPixel(viewSize: CGSize, topInset: CGFloat, backingScale: Double) -> Int {
        let w = Double(viewSize.width)
        let h = Double(viewSize.height - topInset)
        guard w > 0, h > 0, backingScale > 0 else { return 0 }
        let long = (max(w, h) * backingScale).rounded(.up)
        return Int((long / Double(step)).rounded(.up)) * step
    }

    /// 全体表示用の画像を前後それぞれ何枚先読みするか。キャッシュ（`cacheLimit` バイト）に
    /// 今のコマと前後の分が収まる枚数までに絞る（収まらないと、見る前に追い出されてデコードが無駄になる）。
    /// 1 枚の大きさは 3:2（Sony の既定）として見積もる。
    public static func prefetchCount(requested: Int, maxPixel: Int, cacheLimit: Int) -> Int {
        guard requested > 0, maxPixel > 0 else { return 0 }
        let perImage = maxPixel * (maxPixel * 2 / 3) * 4
        let fits = cacheLimit / max(perImage, 1)
        return min(requested, max(0, (fits - 1) / 2))
    }
}

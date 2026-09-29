import Testing
import Foundation
@testable import PhotoPickerCore

@Suite("拡大表示（ZoomState）")
struct ZoomStateTests {
    let focusA = NormalizedPoint(x: 0.7, y: 0.3)
    let focusB = NormalizedPoint(x: 0.25, y: 0.75)
    /// ビュー 1000×800pt（Retina）、画像 6000×4000 画素。fit = 1/3、100% の表示は 3000×2000pt、200% は 6000×4000pt
    let vp = ZoomViewport(viewSize: CGSize(width: 1000, height: 800),
                          imagePixelSize: CGSize(width: 6000, height: 4000), backingScale: 2)
    /// 小さな画像（fit = 2.0 以上になる）
    let smallVP = ZoomViewport(viewSize: CGSize(width: 1000, height: 800),
                               imagePixelSize: CGSize(width: 500, height: 300), backingScale: 2)

    private func zoomed(_ s: Double, at c: NormalizedPoint = NormalizedPoint(x: 0.4, y: 0.6)) -> ZoomState {
        ZoomState(mode: .scale(s), center: c)
    }

    // 操作表: Z
    @Test("Z: 全体表示 → フォーカス位置を 100%")
    func zFromFit() {
        var z = ZoomState()
        z.pressZ(focus: focusA, viewport: vp)
        #expect(z.scale == 1.0)
        #expect(z.center == focusA)
    }

    @Test("Z: 100% → 200%（中心を保つ）")
    func zFrom100() {
        var z = zoomed(1.0)
        z.pressZ(focus: focusA, viewport: vp)
        #expect(z.scale == 2.0)
        #expect(z.center == NormalizedPoint(x: 0.4, y: 0.6))
    }

    @Test("Z: 200% → 全体表示")
    func zFrom200() {
        var z = zoomed(2.0)
        z.pressZ(focus: focusA, viewport: vp)
        #expect(z.isFit)
    }

    @Test("Z: 途中倍率 → 次に大きい段階、200% 以上は全体表示")
    func zFromIntermediate() {
        var a = zoomed(0.5)
        a.pressZ(focus: focusA, viewport: vp)
        #expect(a.scale == 1.0)
        #expect(a.center == NormalizedPoint(x: 0.4, y: 0.6))

        var b = zoomed(1.4)
        b.pressZ(focus: focusA, viewport: vp)
        #expect(b.scale == 2.0)

        var c = zoomed(2.0)
        c.pressZ(focus: focusA, viewport: vp)
        #expect(c.isFit)
    }

    @Test("一度全体に戻してから Z すると、そのコマのフォーカス位置")
    func zAfterReturningToFit() {
        var z = ZoomState()
        z.pressZ(focus: focusA, viewport: vp)
        z.pan(dx: 0.1, dy: 0.1, viewport: vp)
        z.escape()
        #expect(z.isFit)
        z.pressZ(focus: focusB, viewport: vp)
        #expect(z.center == focusB)
        #expect(z.scale == 1.0)
    }

    @Test("Z: 端に寄ったフォーカスは 100% でクランプされる")
    func zClampsFocus() {
        var z = ZoomState()
        z.pressZ(focus: NormalizedPoint(x: 0.99, y: 0.01), viewport: vp)
        // 100%: 表示 3000×2000pt、ビュー 1000×800pt → 半幅 1/6、半高 0.2
        #expect(abs(z.center.x - (1 - 1.0 / 6)) < 1e-9)
        #expect(abs(z.center.y - 0.2) < 1e-9)
    }

    @Test("Z: 100% でクランプ済みの中心を基準に 200%（生の値ではなく）")
    func zKeepsClampedCenter() {
        var z = ZoomState()
        z.pressZ(focus: NormalizedPoint(x: 0.99, y: 0.5), viewport: vp)
        let c100 = z.center.x   // 5/6
        z.pressZ(focus: focusA, viewport: vp)
        #expect(z.scale == 2.0)
        // 200% の範囲は [1/12, 11/12]。100% の端 5/6 はその内側なのでそのまま
        #expect(abs(z.center.x - c100) < 1e-9)
        // 200% から見て範囲外になる中心は 200% でクランプされる
        var w = zoomed(1.0, at: NormalizedPoint(x: 0.5, y: 0.5))
        w.pan(dx: 5, dy: 0, viewport: vp)   // 100% の右端 5/6
        w.pressZ(focus: focusA, viewport: vp)
        #expect(abs(w.center.x - 5.0 / 6) < 1e-9)
    }

    @Test("Z/クリック: fitScale が段階以上（小さな画像）なら段階を飛ばす")
    func skipStagesBelowFit() {
        // smallVP: fit = min(2000/500, 1600/300) = 4 → 段階（1, 2）はすべて fit 以下
        #expect(smallVP.fitScale > 2)
        var z = ZoomState()
        z.pressZ(focus: focusA, viewport: smallVP)
        #expect(z.isFit)
        z.click(at: focusA, viewport: smallVP)
        #expect(z.isFit)

        // fit = 1.5 なら 100% は飛ばして 200%
        let mid = ZoomViewport(viewSize: CGSize(width: 900, height: 900),
                               imagePixelSize: CGSize(width: 1200, height: 1200), backingScale: 2)
        #expect(abs(mid.fitScale - 1.5) < 1e-9)
        var a = ZoomState()
        a.pressZ(focus: focusA, viewport: mid)
        #expect(a.scale == 2.0)
        var b = ZoomState()
        b.click(at: focusA, viewport: mid)
        #expect(b.scale == 2.0)
        // 拡大中: 1.0 より小さい倍率（例 fit 未満相当）でも fit 以下の段階へは進まない
        var c = ZoomState(mode: .scale(1.0), center: NormalizedPoint(x: 0.5, y: 0.5))
        c.pressZ(focus: focusA, viewport: mid)
        #expect(c.scale == 2.0)
    }

    // 操作表: Esc
    @Test("Esc: 全体表示のときは何もなし、拡大中は全体表示")
    func escape() {
        var fit = ZoomState()
        fit.escape()
        #expect(fit == ZoomState())
        var z = zoomed(2.0)
        z.escape()
        #expect(z.isFit)
    }

    // 操作表: クリック
    @Test("クリック: 全体表示 → その点を 100%、拡大中 → 全体表示")
    func click() {
        var z = ZoomState()
        z.click(at: focusB, viewport: vp)
        #expect(z.scale == 1.0)
        #expect(z.center == focusB)
        z.click(at: focusA, viewport: vp)
        #expect(z.isFit)
        var w = zoomed(1.5)
        w.click(at: focusA, viewport: vp)
        #expect(w.isFit)
    }

    @Test("クリック: 端の点は 100% でクランプされる")
    func clickClamps() {
        var z = ZoomState()
        z.click(at: NormalizedPoint(x: 0, y: 1), viewport: vp)
        #expect(abs(z.center.x - 1.0 / 6) < 1e-9)
        #expect(abs(z.center.y - 0.8) < 1e-9)
    }

    // 操作表: ドラッグ
    @Test("ドラッグ: 全体表示では何もなし、拡大中は位置が動き、端でクランプされる")
    func pan() {
        var fit = ZoomState()
        fit.pan(dx: 0.2, dy: 0.2, viewport: vp)
        #expect(fit.isFit)
        #expect(fit.center == NormalizedPoint(x: 0.5, y: 0.5))

        var z = zoomed(1.0, at: NormalizedPoint(x: 0.5, y: 0.5))
        z.pan(dx: 0.1, dy: -0.1, viewport: vp)
        #expect(abs(z.center.x - 0.6) < 1e-9)
        #expect(abs(z.center.y - 0.4) < 1e-9)
        z.pan(dx: 5, dy: -5, viewport: vp)
        #expect(abs(z.center.x - 5.0 / 6) < 1e-9)
        #expect(abs(z.center.y - 0.2) < 1e-9)
        // クランプ済みなので、逆向きに動かすとすぐ戻る（端の外に溜まらない）
        z.pan(dx: -0.1, dy: 0.1, viewport: vp)
        #expect(abs(z.center.x - (5.0 / 6 - 0.1)) < 1e-9)
    }

    // 操作表: ピンチ
    @Test("ピンチ: 全体表示から、指の下の画素が動かないように拡大")
    func pinchFromFit() {
        let fit = vp.fitScale   // 1/3
        var z = ZoomState()
        let anchor = NormalizedPoint(x: 0.7, y: 0.3)
        z.pinch(to: 0.8, anchor: anchor, viewport: vp)
        #expect(z.scale == 0.8)
        let k = fit / 0.8
        // 期待: anchor + (0.5 − anchor) × k、ただし 0.8 での範囲にクランプ
        let expX = anchor.x + (0.5 - anchor.x) * k
        let expY = anchor.y + (0.5 - anchor.y) * k
        let c = vp.clamp(center: NormalizedPoint(x: expX, y: expY), scale: 0.8)
        #expect(abs(z.center.x - c.x) < 1e-9 && abs(z.center.y - c.y) < 1e-9)
        // 指の位置（ビュー上）が変わらない
        let before = ViewportGeometry(viewSize: vp.viewSize, imagePixelSize: vp.imagePixelSize,
                                      backingScale: 2, zoom: ZoomState())
        let after = ViewportGeometry(viewSize: vp.viewSize, imagePixelSize: vp.imagePixelSize,
                                     backingScale: 2, zoom: z)
        let p0 = before.viewPoint(forNormalized: anchor)
        let p1 = after.viewPoint(forNormalized: anchor)
        if z.center == NormalizedPoint(x: expX, y: expY) {
            #expect(abs(p0.x - p1.x) < 1e-6 && abs(p0.y - p1.y) < 1e-6)
        }
    }

    @Test("ピンチ: 拡大中は指の点を軸に拡大・縮小し、200% を超えず、全体表示より小さくならない")
    func pinchClamp() {
        var z = zoomed(1.0, at: NormalizedPoint(x: 0.5, y: 0.5))
        let anchor = NormalizedPoint(x: 0.6, y: 0.5)   // 中心の右 0.1
        z.pinch(to: 1.5, anchor: anchor, viewport: vp)
        #expect(z.scale == 1.5)
        // k = 1/1.5、x = 0.6 + (0.5 − 0.6) × 2/3
        #expect(abs(z.center.x - (0.6 - 0.1 * 2.0 / 3)) < 1e-9)
        #expect(abs(z.center.y - 0.5) < 1e-9)
        z.pinch(to: 5.0, anchor: anchor, viewport: vp)
        #expect(z.scale == 2.0)
        z.pinch(to: 0.1, anchor: anchor, viewport: vp)
        #expect(z.isFit)
    }

    @Test("ピンチ: 指の下の画素が拡大前後でビュー上の同じ位置に留まる（拡大中）")
    func pinchKeepsPointUnderFinger() {
        var z = zoomed(1.0, at: NormalizedPoint(x: 0.5, y: 0.5))
        let g0 = ViewportGeometry(viewSize: vp.viewSize, imagePixelSize: vp.imagePixelSize, backingScale: 2, zoom: z)
        let finger = CGPoint(x: 700, y: 300)
        let anchor = g0.normalizedPoint(forViewPoint: finger)
        z.pinch(to: 1.6, anchor: anchor, viewport: vp)
        let g1 = ViewportGeometry(viewSize: vp.viewSize, imagePixelSize: vp.imagePixelSize, backingScale: 2, zoom: z)
        let p = g1.viewPoint(forNormalized: anchor)
        #expect(abs(p.x - finger.x) < 1e-6 && abs(p.y - finger.y) < 1e-6)
    }

    @Test("ピンチ: 全体表示から 1 イベントの変化が小さくても、累積が超えれば拡大が始まる")
    func pinchCumulativeFromFit() {
        let fit = vp.fitScale
        var z = ZoomState()
        // 累積 1.005 ではまだ全体表示のまま
        z.pinch(to: ZoomState.pinchTarget(startScale: fit, magnification: 1.005), anchor: focusA, viewport: vp)
        #expect(z.isFit)
        // 累積 1.05 で拡大が始まる
        z.pinch(to: ZoomState.pinchTarget(startScale: fit, magnification: 1.05), anchor: focusA, viewport: vp)
        #expect(abs((z.scale ?? 0) - fit * 1.05) < 1e-9)
    }

    // 操作表: F / フォーカス位置へ
    @Test("F: 全体表示なら Z と同じ、拡大中は倍率を保って中心だけ移す")
    func moveToFocus() {
        var fit = ZoomState()
        fit.moveToFocus(focus: focusA, viewport: vp)
        #expect(fit.scale == 1.0)
        #expect(fit.center == focusA)

        var z = zoomed(1.5)
        z.moveToFocus(focus: focusB, viewport: vp)
        #expect(z.scale == 1.5)
        #expect(z.center == focusB)

        var e = zoomed(1.0)
        e.moveToFocus(focus: NormalizedPoint(x: 1, y: 1), viewport: vp)
        #expect(abs(e.center.x - 5.0 / 6) < 1e-9 && abs(e.center.y - 0.8) < 1e-9)
    }

    // コマ移動
    @Test("コマ移動: 同じグループなら位置・倍率を保つ")
    func moveSameGroup() {
        var z = zoomed(1.5)
        z.didMoveToItem(sameGroup: true, focus: focusA, viewport: vp)
        #expect(z.scale == 1.5)
        #expect(z.center == NormalizedPoint(x: 0.4, y: 0.6))
    }

    @Test("コマ移動: 別グループなら倍率を保ってフォーカス位置へ（クランプ）")
    func moveOtherGroup() {
        var z = zoomed(1.5)
        z.didMoveToItem(sameGroup: false, focus: focusA, viewport: vp)
        #expect(z.scale == 1.5)
        #expect(z.center == focusA)
        z.didMoveToItem(sameGroup: false, focus: NormalizedPoint(x: 0, y: 0), viewport: vp)
        let f = vp.viewFraction(scale: 1.5)
        #expect(abs(z.center.x - f.width / 2) < 1e-9 && abs(z.center.y - f.height / 2) < 1e-9)
    }

    @Test("コマ移動: 同じグループでも移り先の大きさでクランプし直す")
    func moveSameGroupReclamps() {
        var z = zoomed(1.0, at: NormalizedPoint(x: 0.95, y: 0.5))
        let other = ZoomViewport(viewSize: vp.viewSize, imagePixelSize: CGSize(width: 12000, height: 4000), backingScale: 2)
        z.didMoveToItem(sameGroup: true, focus: focusA, viewport: other)
        // 幅 12000 画素 → 100% の半幅 1/12
        #expect(abs(z.center.x - (1 - 1.0 / 12)) < 1e-9)
    }

    @Test("コマ移動: 移り先の全体表示倍率以下になったら全体表示に戻す")
    func moveToSmallImageResetsToFit() {
        // smallVP の fit は 2.0 以上。100% のまま移ると fit 以下なので全体表示へ
        var z = zoomed(1.0)
        z.didMoveToItem(sameGroup: true, focus: focusA, viewport: smallVP)
        #expect(z.isFit)
        #expect(z.center == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test("コマ移動: 全体表示のままなら変わらない")
    func moveInFit() {
        var z = ZoomState()
        z.didMoveToItem(sameGroup: false, focus: focusA, viewport: vp)
        #expect(z.isFit)
    }

    // 端のクランプ
    @Test("表示端のクランプ")
    func clampCenter() {
        // ZoomViewport.clamp: 100% の表示は 3000×2000pt、ビュー 1000×800 → 幅 1/3、高さ 0.4
        let c = vp.clamp(center: NormalizedPoint(x: 0.99, y: 0.01), scale: 1.0)
        #expect(abs(c.x - 5.0 / 6) < 1e-9)
        #expect(abs(c.y - 0.2) < 1e-9)
        // 画像がビューに収まる軸は中央
        let s = smallVP.clamp(center: NormalizedPoint(x: 0.9, y: 0.1), scale: 2.0)
        #expect(s.x == 0.5 && s.y == 0.5)
        // ViewportGeometry.clampedCenter も同じ結果
        let g = ViewportGeometry(viewSize: vp.viewSize, imagePixelSize: vp.imagePixelSize, backingScale: 2,
                                 zoom: zoomed(1.0, at: NormalizedPoint(x: 0.99, y: 0.01)))
        #expect(abs(g.clampedCenter.x - 5.0 / 6) < 1e-9 && abs(g.clampedCenter.y - 0.2) < 1e-9)

        // ビューが変わったとき（viewport 版）
        var w = zoomed(1.0, at: NormalizedPoint(x: 0.99, y: 0.5))
        w.clampCenter(viewport: vp)
        #expect(abs(w.center.x - 5.0 / 6) < 1e-9)
    }

    @Test("ViewportGeometry: 100% で 1 画素 = 1 物理ピクセル、全体表示は収まる")
    func geometry() {
        let img = CGSize(width: 6000, height: 4000)
        let fit = ViewportGeometry(viewSize: CGSize(width: 1000, height: 800), imagePixelSize: img,
                                   backingScale: 2, zoom: ZoomState())
        #expect(abs(fit.fitScale - (2000.0 / 6000.0)) < 1e-9)
        #expect(abs(fit.imageRect.width - 1000) < 1e-6)
        #expect(abs(fit.imageRect.midY - 400) < 1e-6)

        var z = ZoomState()
        z.pressZ(focus: NormalizedPoint(x: 0.5, y: 0.5), viewport: vp)
        let g = ViewportGeometry(viewSize: CGSize(width: 1000, height: 800), imagePixelSize: img,
                                 backingScale: 2, zoom: z)
        #expect(abs(g.displaySize.width - 3000) < 1e-6)
        // 中心がビューの中央に来る
        let p = g.viewPoint(forNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        #expect(abs(p.x - 500) < 1e-6 && abs(p.y - 400) < 1e-6)
    }

    @Test("全体表示は上端の空き（ツールバー）の下に収まり、拡大中はビュー全体を使う")
    func topInsetLayout() {
        let img = CGSize(width: 6000, height: 4000)
        // ビュー 1000×800pt、上端 100pt を空ける → 全体表示の領域は 1000×700。画像は 3:2 なので高さ 667 の幅 1000
        let fit = ViewportGeometry(viewSize: CGSize(width: 1000, height: 800), imagePixelSize: img,
                                   backingScale: 2, zoom: ZoomState(), topInset: 100)
        let r = fit.imageRect
        #expect(r.minY >= 100 - 1e-6)
        #expect(abs(r.midY - 450) < 1e-6)                   // 領域 (100...800) の中央
        #expect(abs(fit.fitScale - min(2000.0 / 6000, 1400.0 / 4000)) < 1e-9)
        // 全体表示のクリック座標 ↔ 正規化座標が rect と一貫
        let center = fit.normalizedPoint(forViewPoint: CGPoint(x: r.midX, y: r.midY))
        #expect(abs(center.x - 0.5) < 1e-9 && abs(center.y - 0.5) < 1e-9)
        let back = fit.viewPoint(forNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        #expect(abs(back.x - r.midX) < 1e-9 && abs(back.y - r.midY) < 1e-9)

        // 拡大中はビュー全体の中央が中心（上端の空きは使わない）
        var z = ZoomState()
        let viewport = fit.viewport
        z.pressZ(focus: NormalizedPoint(x: 0.5, y: 0.5), viewport: viewport)
        let zoomed = ViewportGeometry(viewSize: CGSize(width: 1000, height: 800), imagePixelSize: img,
                                      backingScale: 2, zoom: z, topInset: 100)
        let p = zoomed.viewPoint(forNormalized: NormalizedPoint(x: 0.5, y: 0.5))
        #expect(abs(p.x - 500) < 1e-6 && abs(p.y - 400) < 1e-6)
        // ZoomViewport の clamp はビュー全体（800pt）を基準にする
        let f = viewport.viewFraction(scale: 1.0)
        #expect(abs(f.height - 800.0 / 2000.0) < 1e-9)
    }
}

import SwiftUI
import AppKit
import QuartzCore
import JPPhotoPickerCore

/// 画像の表示・ドラッグ・2本指スクロール・ホイール・⌘+スクロール・ピンチ・クリックを受ける NSView のラッパー。
/// 表示位置は `ViewportGeometry.imageRect`（ZoomState と一貫した計算）に従い、レイヤーを直接動かす。
/// 判定ロジックは持たず、入力を `BrowserModel` の操作に渡すだけ。
/// ピンチの段階。`changed` の倍率は、ジェスチャー開始からの累積倍率。
enum PinchPhase {
    case began
    case changed
    case ended
}

struct ZoomableImageView: NSViewRepresentable {
    let image: PipelineImage?
    let imageRect: CGRect
    let isZoomed: Bool
    /// 上端のタイトルバー（ツールバー）の高さ。この範囲のクリック・ドラッグはウインドウの操作に回す
    let titlebarHeight: CGFloat
    let onClick: (CGPoint) -> Void
    let onPan: (CGSize) -> Void
    let onPinch: (PinchPhase, Double, CGPoint) -> Void

    func makeNSView(context: Context) -> ZoomCanvasView {
        ZoomCanvasView()
    }

    func updateNSView(_ view: ZoomCanvasView, context: Context) {
        view.onClick = onClick
        view.onPan = onPan
        view.onPinch = onPinch
        view.isZoomed = isZoomed
        view.titlebarHeight = titlebarHeight
        view.update(image: image, imageRect: imageRect)
    }
}

final class ZoomCanvasView: NSView {
    var onClick: ((CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onPinch: ((PinchPhase, Double, CGPoint) -> Void)?
    var isZoomed = false
    var titlebarHeight: CGFloat = 0

    private let imageLayer = CALayer()
    private var currentImage: PipelineImage?
    private var imageRect: CGRect = .zero
    private var mouseDownPoint: CGPoint?
    private var isDragging = false
    /// mouseDown の時点でウインドウがキーだったか（前面化のためのクリックでは拡大しない）
    private var downWasKey = false
    private var pinchActive = false
    private var pinchTotal = 1.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    /// ウインドウを前面に出すだけのクリックは受け取らない
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func update(image: PipelineImage?, imageRect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== currentImage {
            currentImage = image
            imageLayer.contents = image?.layerContents
        }
        self.imageRect = imageRect
        applyRect()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRect()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// SwiftUI 側の座標（左上原点）→ レイヤー座標（左下原点）
    private func applyRect() {
        let r = imageRect
        imageLayer.frame = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// NSView 座標 → 左上原点のビュー座標
    private func topLeftPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: 入力

    override func mouseDown(with event: NSEvent) {
        let point = topLeftPoint(convert(event.locationInWindow, from: nil))
        // 写真はタイトルバーの下まで描いているので、その範囲ではタイトルバーと同じ動きをさせる
        if point.y < titlebarHeight {
            mouseDownPoint = nil
            titlebarMouseDown(with: event)
            return
        }
        mouseDownPoint = point
        isDragging = false
        downWasKey = window?.isKeyWindow ?? false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = topLeftPoint(convert(event.locationInWindow, from: nil))
        if !isDragging, hypot(p.x - start.x, p.y - start.y) > 4 { isDragging = true }
        if isDragging, isZoomed {
            onPan?(CGSize(width: event.deltaX, height: event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; isDragging = false }
        // ダブルクリック（2 回目以降）と、前面化のクリックは無視する
        guard !isDragging, downWasKey, event.clickCount <= 1, let p = mouseDownPoint else { return }
        onClick?(p)
    }

    /// タイトルバーのダブルクリックはシステム設定（デスクトップと Dock）に従い、それ以外はウインドウを動かす
    private func titlebarMouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        case "Maximize": window.performZoom(nil)
        default: Self.toggleFill(window)   // 未設定（既定）と「フィル」
        }
    }

    /// フィルする前のウインドウの位置と大きさ（もう一度ダブルクリックしたときに戻す）
    private static var framesBeforeFill: [ObjectIdentifier: NSRect] = [:]

    /// 画面いっぱい（Dock とメニューバーを除く）と元の大きさを切り替える。
    /// フィルした後に手で動かしていたら、もう一度フィルする
    private static func toggleFill(_ window: NSWindow) {
        guard let visible = window.screen?.visibleFrame else { return }
        let key = ObjectIdentifier(window)
        let isFilled = abs(window.frame.minX - visible.minX) < 2 && abs(window.frame.minY - visible.minY) < 2
            && abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
        if isFilled, let saved = framesBeforeFill.removeValue(forKey: key) {
            window.setFrame(saved, display: true, animate: true)
        } else if !isFilled {
            framesBeforeFill[key] = window.frame
            window.setFrame(visible, display: true, animate: true)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // トラックパッド・Magic Mouse（滑らかな入力）はパン、マウスのホイールはズーム。
        // ⌘ を押しながらなら、滑らかな入力でもズームする（Magic Mouse はピンチできないため）
        guard event.hasPreciseScrollingDeltas else {
            wheelZoom(with: event)
            return
        }
        if event.modifierFlags.contains(.command) {
            smoothZoom(with: event)
            return
        }
        guard isZoomed else { return }
        onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }

    /// 滑らかな入力 1 ポイントあたりの倍率の変化（対数）
    private static let smoothZoomRate = 0.006

    /// ⌘ + 滑らかなスクロールのズーム。遊びは設けず、1 イベントごとに今の倍率を起点に変える。
    /// 指を離した後の慣性ではズームしない。
    private func smoothZoom(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        // ナチュラルスクロールの設定に関係なく、奥へ動かすと拡大
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard dy != 0 else { return }
        let p = topLeftPoint(convert(event.locationInWindow, from: nil))
        onPinch?(.began, 1, p)
        onPinch?(.changed, exp(Double(dy) * Self.smoothZoomRate), p)
        onPinch?(.ended, 1, p)
    }

    // MARK: ホイールズーム

    /// ズームを始めるまでの遊び（行数）
    private static let wheelDeadZone: CGFloat = 3
    /// 1 行あたりの倍率
    private static let wheelStep = 1.12
    /// この秒数ホイールが止まったら遊びを戻す
    private static let wheelIdleReset: TimeInterval = 0.4

    private var wheelAccum: CGFloat = 0
    private var wheelEngaged = false
    private var lastWheelTime: TimeInterval = 0

    /// 遊びを越えるまでは溜めるだけ。越えたら 1 回ごとに今の倍率を起点にズームする（上限で回し過ぎても戻しが効く）。
    private func wheelZoom(with event: NSEvent) {
        // ナチュラルスクロールの設定に関係なく、奥へ回すと拡大
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard dy != 0 else { return }
        if event.timestamp - lastWheelTime > Self.wheelIdleReset {
            wheelAccum = 0
            wheelEngaged = false
        }
        lastWheelTime = event.timestamp
        if !wheelEngaged {
            // 逆向きに回したら溜めた分は捨てる
            if wheelAccum != 0, (wheelAccum > 0) != (dy > 0) { wheelAccum = 0 }
            wheelAccum += dy
            guard abs(wheelAccum) >= Self.wheelDeadZone else { return }
            wheelEngaged = true
        }
        let p = topLeftPoint(convert(event.locationInWindow, from: nil))
        onPinch?(.began, 1, p)
        onPinch?(.changed, pow(Self.wheelStep, Double(dy)), p)
        onPinch?(.ended, 1, p)
    }

    override func magnify(with event: NSEvent) {
        let p = topLeftPoint(convert(event.locationInWindow, from: nil))
        let phase = event.phase
        if phase.contains(.began) || !pinchActive {
            pinchActive = true
            pinchTotal = 1
            onPinch?(.began, 1, p)
        }
        pinchTotal *= max(1 + Double(event.magnification), 0.01)
        onPinch?(.changed, pinchTotal, p)
        // phase が空（フェーズを持たない入力）のときは 1 イベントで完結させる
        if phase.contains(.ended) || phase.contains(.cancelled) || phase.isEmpty {
            pinchActive = false
            onPinch?(.ended, pinchTotal, p)
        }
    }
}

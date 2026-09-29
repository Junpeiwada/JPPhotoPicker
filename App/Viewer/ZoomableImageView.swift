import SwiftUI
import AppKit
import QuartzCore
import PhotoPickerCore

/// 画像の表示・ドラッグ・2本指スクロール・ピンチ・クリックを受ける NSView のラッパー。
/// 表示位置は `ViewportGeometry.imageRect`（ZoomState と一貫した計算）に従い、レイヤーを直接動かす。
/// 判定ロジックは持たず、入力を `BrowserModel` の操作に渡すだけ。
/// ピンチの段階。`changed` の倍率は、ジェスチャー開始からの累積倍率。
enum PinchPhase {
    case began
    case changed
    case ended
}

struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage?
    let imageRect: CGRect
    let isZoomed: Bool
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
        view.update(image: image, imageRect: imageRect)
    }
}

final class ZoomCanvasView: NSView {
    var onClick: ((CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onPinch: ((PinchPhase, Double, CGPoint) -> Void)?
    var isZoomed = false

    private let imageLayer = CALayer()
    private var currentImage: CGImage?
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

    func update(image: CGImage?, imageRect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== currentImage {
            currentImage = image
            imageLayer.contents = image
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
        mouseDownPoint = topLeftPoint(convert(event.locationInWindow, from: nil))
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

    override func scrollWheel(with event: NSEvent) {
        guard isZoomed else { return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        onPan?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
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

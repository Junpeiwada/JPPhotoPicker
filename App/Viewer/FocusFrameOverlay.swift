import SwiftUI
import PhotoPickerCore

/// フォーカス枠。通常表示・拡大表示のどちらでも、表示中の画像の位置に合わせて描く。
/// `frameSize` が nil（フォーカス位置なし・枠無効）のときは何も描かない。
struct FocusFrameOverlay: View {
    let focus: FocusGeometry
    let geometry: ViewportGeometry

    var body: some View {
        if let size = focus.frameSize, focus.hasFocusPosition, geometry.isValid {
            let rect = geometry.imageRect
            let center = geometry.viewPoint(forNormalized: focus.center)
            let w = max(size.width * rect.width, 8)
            let h = max(size.height * rect.height, 8)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.yellow.opacity(0.95), lineWidth: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .frame(width: w, height: h)
                .position(x: center.x, y: center.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

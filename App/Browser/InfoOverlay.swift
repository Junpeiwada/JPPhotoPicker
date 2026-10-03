import SwiftUI
import JPPhotoPickerCore

/// プレビューの左上に重ねる撮影情報（I で切り替え）。パネルは敷かず、文字だけを出す。
/// 写真と混ざらないよう、白い文字に黒い外枠（4 方向の影）と軽いぼかしの影を付ける。
/// 写真のクリック・ドラッグを邪魔しないよう、マウス操作は受けない。
struct InfoOverlay: View {
    @Environment(BrowserModel.self) private var model
    let item: PhotoItem
    var maxWidth: CGFloat = Self.maxWidth

    static let maxWidth: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.id).font(.headline).monospaced()
            // 主要項目と Sony の項目は 1 つの表にして、値の左端をそろえる
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                rows(model.infoCache[item.id]?.summary ?? [])
                let sony = item.metadata?.sonyInfoRows ?? []
                if !sony.isEmpty {
                    Color.clear.frame(height: 6).gridCellUnsizedAxes(.horizontal)
                    rows(sony)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .frame(maxWidth: maxWidth, alignment: .leading)
        // まとめて 1 枚にしてから影を付ける（行ごとに影を描かない）
        .compositingGroup()
        .shadow(color: .black, radius: 0, x: 1, y: 0)
        .shadow(color: .black, radius: 0, x: -1, y: 0)
        .shadow(color: .black, radius: 0, x: 0, y: 1)
        .shadow(color: .black, radius: 0, x: 0, y: -1)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .allowsHitTesting(false)
        .task(id: item.id) { await model.loadInfo(for: item) }
    }

    private func rows(_ rows: [PhotoInfoRow]) -> some View {
        ForEach(rows) { row in
            GridRow {
                Text(row.label)
                    .foregroundStyle(.white.opacity(0.75))
                Text(row.value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

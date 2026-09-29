import SwiftUI
import PhotoPickerCore

/// 下部のフィルムストリップ。横スクロール、連写グループはうっすらした背景と角丸でまとめる。
/// 1 コマ単位の LazyHStack に平らに並べ、グループの背景は各セルが「先頭 / 中 / 末尾」に応じて描く。
struct FilmstripView: View {
    @Environment(BrowserModel.self) private var model

    static let cellHeight: CGFloat = 76

    /// コマの幅。本体の縦横比（表示向き）に合わせる。メタデータが無ければ 3:2
    static func cellWidth(for item: PhotoItem) -> CGFloat {
        var aspect = 1.5
        if let m = item.metadata, let w = m.imageWidth, let h = m.imageHeight, w > 0, h > 0 {
            aspect = (5...8).contains(m.orientation) ? Double(h) / Double(w) : Double(w) / Double(h)
        }
        return (cellHeight * aspect).rounded()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    // ForEach の中ではモデルの判定・現在コマを読まない（読むと、判定のたびに全コマ分の
                    // 本体が再評価される）。読み取りは、表示中のセルだけを作る FilmstripCellHost が行う。
                    ForEach(model.entries) { entry in
                        FilmstripCellHost(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            // 現在のコマを追従させる（body で currentIndex を読まないよう別ビューに分ける）
            .background { ScrollFollower(proxy: proxy) }
        }
        .frame(height: Self.cellHeight + 12 + 8)
        .background(.black.opacity(0.25))
    }
}

/// 現在のコマが変わったらフィルムストリップをスクロールする。アニメーションなし。
private struct ScrollFollower: View {
    @Environment(BrowserModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: model.currentItem?.id, initial: true) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
                // 初回など、レイアウトが済む前の呼び出しに備えて 1 周期後にもう一度
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
    }
}

/// 1 コマ分の判定・現在コマをモデルから読み、値だけをセルに渡す（セル自体はモデルを観測しない）
private struct FilmstripCellHost: View {
    @Environment(BrowserModel.self) private var model
    let entry: BrowserEntry

    var body: some View {
        FilmstripCell(
            entry: entry,
            decision: model.decision(for: entry.item),
            isCurrent: model.currentItem?.id == entry.id,
            pipeline: model.pipeline,
            onSelect: { [model] id in model.select(id: id) })
    }
}

private struct FilmstripCell: View {
    let entry: BrowserEntry
    let decision: Decision
    let isCurrent: Bool
    let pipeline: ImagePipeline
    let onSelect: (String) -> Void
    @State private var thumbnail: CGImage?

    private var item: PhotoItem { entry.item }
    private var isFirst: Bool { entry.positionInGroup == 0 }
    private var isLast: Bool { entry.positionInGroup == entry.groupCount - 1 }

    var body: some View {
        Button {
            onSelect(entry.id)
        } label: {
            thumbnailView
        }
        .buttonStyle(.plain)
        // 連写グループの背景（先頭・末尾だけ角を丸める）。グループ内の隙間もこの背景で埋まる
        .padding(.leading, entry.isBurst && isFirst ? 4 : 0)
        .padding(.trailing, entry.isBurst ? 4 : 0)
        .padding(.vertical, entry.isBurst ? 4 : 0)
        .background {
            if entry.isBurst {
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? 10 : 0, bottomLeadingRadius: isFirst ? 10 : 0,
                    bottomTrailingRadius: isLast ? 10 : 0, topTrailingRadius: isLast ? 10 : 0,
                    style: .continuous)
                    .fill(.white.opacity(0.08))
            }
        }
        // グループ間・単写どうしの間隔
        .padding(.leading, entry.isBurst ? (isFirst ? 3 : 0) : 3)
        .padding(.trailing, entry.isBurst ? (isLast ? 3 : 0) : 3)
        .task(id: item.id) {
            if let c = pipeline.cached(.thumbnail, for: item) {
                thumbnail = c
            } else {
                // 待つ間にセルが消えた（キャンセル）ときは代入しない
                let image = await pipeline.load(.thumbnail, for: item, queuePriority: .normal)
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.12))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(decision == .rejected ? 0.3 : 1)
            }
        }
        .frame(width: FilmstripView.cellWidth(for: item), height: FilmstripView.cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) { decisionMark }
        .overlay(alignment: .topLeading) {
            if item.kind == .arwOnly {
                Text("ARW")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(4)
            }
        }
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var decisionMark: some View {
        switch decision {
        case .picked:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.system(size: 18))
                .padding(4)
        case .rejected:
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(6)
        case .undecided:
            EmptyView()
        }
    }

    private var label: String {
        var base = item.kind == .arwOnly ? item.id + "、ARW だけ" : item.id
        if entry.isBurst { base += "、連写 \(entry.groupCount) 枚中 \(entry.positionInGroup + 1) 枚目" }
        return switch decision {
        case .picked: base + "、採用"
        case .rejected: base + "、不採用"
        case .undecided: base
        }
    }
}

import SwiftUI
import JPPhotoPickerCore

/// 下部のフィルムストリップ。横スクロール、グループ（単写は 1 枚で 1 グループ）は間隔で区切り、
/// 今のグループだけ下線を引く。1 コマ単位の LazyHStack に平らに並べ、下線は各セルが「先頭 / 中 / 末尾」に応じて描く。
struct FilmstripView: View {
    @Environment(BrowserModel.self) private var model

    static let cellHeight: CGFloat = 76
    /// グループ内のコマの間隔
    static let innerGap: CGFloat = 4
    /// グループどうしの間隔
    static let groupGap: CGFloat = 14
    /// サムネイルの下に取る、下線用の余白（下線を含む）
    static let underlineSpace: CGFloat = 7

    /// コマの幅。本体の縦横比（表示向き）に合わせる。メタデータが無ければ 3:2
    static func cellWidth(for item: PhotoItem) -> CGFloat {
        var aspect: CGFloat = 1.5
        if let size = item.metadata?.displayPixelSize { aspect = size.width / size.height }
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
        .frame(height: Self.cellHeight + Self.underlineSpace + 12 + 8)
        .background(.black.opacity(0.25))
    }
}

/// 現在のコマが変わったらフィルムストリップをスクロールする。コマ送りでは短くアニメーションする。
private struct ScrollFollower: View {
    @Environment(BrowserModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: model.currentItem?.id, initial: true) { old, id in
                guard let id else { return }
                if old == nil || old == id {
                    // 初回・フォルダを開いた直後はアニメーションなし。
                    // レイアウトが済む前の呼び出しに備えて 1 周期後にもう一度
                    proxy.scrollTo(id, anchor: .center)
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                } else {
                    withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) }                }
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
            isInCurrentGroup: model.currentEntry?.groupIndex == entry.groupIndex,
            pipeline: model.pipeline,
            onSelect: { [model] id in model.select(id: id) })
    }
}

private struct FilmstripCell: View {
    let entry: BrowserEntry
    let decision: Decision
    let isCurrent: Bool
    let isInCurrentGroup: Bool
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
        // グループ内の隙間（下線はこの隙間もつないで引く）
        .padding(.trailing, isLast ? 0 : FilmstripView.innerGap)
        .padding(.bottom, FilmstripView.underlineSpace)
        .overlay(alignment: .bottom) {
            if isInCurrentGroup {
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? 1.5 : 0, bottomLeadingRadius: isFirst ? 1.5 : 0,
                    bottomTrailingRadius: isLast ? 1.5 : 0, topTrailingRadius: isLast ? 1.5 : 0,
                    style: .continuous)
                    .fill(Color.orange)
                    .frame(height: 3)
            }
        }
        // グループ間の間隔（単写も 1 枚で 1 グループ）
        .padding(.leading, isFirst ? FilmstripView.groupGap / 2 : 0)
        .padding(.trailing, isLast ? FilmstripView.groupGap / 2 : 0)
        .task(id: item.id) {
            if let c = pipeline.cached(.thumbnail, for: item) {
                thumbnail = c.cgImage
            } else {
                // 待つ間にセルが消えた（キャンセル）ときは代入しない
                let image = await pipeline.load(.thumbnail, for: item, queuePriority: .normal)
                guard !Task.isCancelled else { return }
                thumbnail = image?.cgImage
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
        case .undecided:
            EmptyView()
        }
    }

    private var label: String { entry.spokenDescription(decision: decision) }
}

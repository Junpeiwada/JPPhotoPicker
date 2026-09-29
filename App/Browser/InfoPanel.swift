import SwiftUI
import PhotoPickerCore

/// プレビューの右側に重ねる情報パネル（EXIF）。上段に主要項目、下段に全タグを辞書ごとに折りたたんで並べる。
/// 写真の上に重ねるので、読めるように暗めのガラスにする。
struct InfoPanel: View {
    @Environment(BrowserModel.self) private var model
    let item: PhotoItem

    /// 開いている全タグのまとまり（コマを移っても保つ）
    @AppStorage("infoExpandedSections") private var expandedRaw = ""

    static let width: CGFloat = 320

    var body: some View {
        let info = model.infoCache[item.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.id).font(.headline).monospaced()

                if let info {
                    rows(info.summary, font: .callout)
                } else {
                    ProgressView().controlSize(.small)
                }

                let sony = item.metadata?.sonyInfoRows ?? []
                if !sony.isEmpty {
                    section("Sony MakerNote", rows: sony)
                }
                if let info {
                    ForEach(info.sections) { s in
                        section(s.title, rows: s.rows)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .textSelection(.enabled)
        .frame(width: Self.width)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: .rect(cornerRadius: 18))
        .task(id: item.id) { await model.loadInfo(for: item) }
    }

    private func rows(_ rows: [PhotoInfoRow], font: Font) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(font)
    }

    private func section(_ title: String, rows: [PhotoInfoRow]) -> some View {
        DisclosureGroup(isExpanded: expanded(title)) {
            self.rows(rows, font: .caption)
                .padding(.top, 4)
        } label: {
            Text("\(title)（\(rows.count)）").font(.subheadline.weight(.semibold))
        }
    }

    private func expanded(_ title: String) -> Binding<Bool> {
        Binding {
            expandedRaw.split(separator: "\n").contains { $0 == title }
        } set: { isOn in
            var set = Set(expandedRaw.split(separator: "\n").map(String.init))
            if isOn { set.insert(title) } else { set.remove(title) }
            expandedRaw = set.sorted().joined(separator: "\n")
        }
    }
}

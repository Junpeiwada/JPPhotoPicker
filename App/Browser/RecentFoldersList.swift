import SwiftUI
import JPPhotoPickerCore

/// 起動画面の「最近開いたフォルダ」。1 クリックで開く。
/// 見つからないフォルダは薄く出す（押すと見つからない旨を知らせる。右クリックで履歴から削除できるよう、無効にはしない）。
struct RecentFoldersList: View {
    @Environment(BrowserModel.self) private var model
    /// パス → フォルダがあるか。確認はバックグラウンドで行う（応答しないネットワークドライブで画面を止めない）。
    /// 確認前は「ある」として出す
    @State private var existence: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近開いたフォルダ")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            VStack(spacing: 2) {
                ForEach(model.recentFolders.items) { folder in
                    RecentFolderRow(folder: folder, exists: existence[folder.path] ?? true)
                }
            }
        }
        .frame(maxWidth: 560)
        .task(id: model.recentFolders) { await refreshExistence() }
        // ディスクを付け外ししたら確認し直す
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await refreshExistence() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await refreshExistence() }
        }
    }

    private func refreshExistence() async {
        existence = await Self.checkExistence(model.recentFolders.items.map(\.url))
    }

    @concurrent
    private static func checkExistence(_ urls: [URL]) async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for url in urls { result[url.path] = BrowserModel.folderExists(url) }
        return result
    }
}

private struct RecentFolderRow: View {
    @Environment(BrowserModel.self) private var model
    let folder: RecentFolder
    let exists: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            model.open(recent: folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: exists ? "folder.fill" : "questionmark.folder")
                    .font(.title3)
                    .foregroundStyle(exists ? Color.accentColor : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(folder.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(exists ? folder.openedAt.formatted(.relative(presentation: .named)) : "見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered && exists ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(exists ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .help(folder.path)
        .contextMenu {
            Button("Finder に表示") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                .disabled(!exists)
            Button("履歴から削除") { model.removeRecent(folder) }
        }
        .accessibilityLabel(exists ? "\(folder.name)、\(folder.parentPath)" : "\(folder.name)、見つかりません")
    }
}

import SwiftUI
import UniformTypeIdentifiers
import JPPhotoPickerCore

/// メインウインドウの中身。フォルダ未選択なら案内、選択後はプレビュー＋フィルムストリップ。
/// 写真閲覧向けに、ウインドウ全体をダークで統一する。
struct BrowserView: View {
    @Environment(BrowserModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model

        content
            // 余白も含めたウインドウ全体でドロップを受ける
            .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
            .contentShape(Rectangle())
            .applyFlow(model)
            // フォルダ選択（標準のファイル選択シート）
            .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.open(folder: url) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.open(dropped: urls)
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle(model.folderName ?? "JPPhotoPicker")
            .focusedSceneValue(\.browserModel, model)
            // 適用・取り消しの実行中はウインドウを閉じさせない
            .background { WindowCloseGuard(model: model) }
            .background { spaceToPick }
            .preferredColorScheme(.dark)
    }

    /// スペースでも採用を切り替える（P と同じ）。メニュー項目のショートカットは1つしか付けられないので、
    /// 見えないボタンで受ける。`.hidden()` にするとショートカットが効かなくなるため透明・大きさ0にする
    private var spaceToPick: some View {
        Button("採用") { model.togglePick() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.hasEntries || !model.isInteractive)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasFolder {
            // 最近開いたフォルダは ContentUnavailableView の外に置く（中だと幅が狭く、パスが読めない）
            VStack(spacing: 8) {
                ContentUnavailableView {
                    Label("フォルダを開いてください", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("写真が入ったフォルダをここへドラッグするか、［フォルダを開く］を選んでください。")
                } actions: {
                    Button("フォルダを開く…") { model.chooseFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !model.recentFolders.items.isEmpty {
                    RecentFoldersList()
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading {
            ProgressView("読み込み中…")
        } else if !model.hasEntries {
            ContentUnavailableView {
                Label("写真が見つかりません", systemImage: "photo")
            } description: {
                Text(model.errorMessage ?? "このフォルダには JPG / ARW がありません。")
            } actions: {
                Button("別のフォルダを開く…") { model.chooseFolder() }
            }
        } else {
            VStack(spacing: 0) {
                PreviewView()
                FilmstripView()
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import PhotoPickerCore

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
            .navigationTitle(model.folderName ?? "PhotoPicker")
            .navigationSubtitle(model.progressText)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.chooseFolder() } label: {
                        Label("フォルダを開く", systemImage: "folder")
                    }
                    .disabled(model.isBusy || model.isModalPresented)
                    .help("フォルダを開く（⌘O）")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.requestApply() } label: {
                        Label("適用", systemImage: "tray.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(!model.canApply || model.isModalPresented)
                    .help(model.applyDisabledReason
                          ?? "不採用のコマと、連写で採用しなかったコマを _rejected に移します")
                }
                // 右端: 情報パネルの切り替え
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $model.showInfo) {
                        Label("情報", systemImage: "info.circle")
                    }
                    .disabled(!model.hasEntries)
                    .help("撮影情報（EXIF）を表示します（I）")
                }
            }
            .focusedSceneValue(\.browserModel, model)
            // 適用・取り消しの実行中はウインドウを閉じさせない
            .background { WindowCloseGuard(model: model) }
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasFolder {
            ContentUnavailableView {
                Label("フォルダを開いてください", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("写真が入ったフォルダをここへドラッグするか、［フォルダを開く］を選んでください。")
            } actions: {
                Button("フォルダを開く…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
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

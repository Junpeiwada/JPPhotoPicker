import SwiftUI
import JPPhotoPickerCore

/// 適用・取り消しの確認ダイアログ、通知、失敗一覧シート、実行中の進捗表示をまとめて付ける。
private struct ApplyFlowModifier: ViewModifier {
    @Bindable var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .disabled(model.isBusy)
            .overlay {
                if let message = model.busyMessage {
                    ProgressView(message)
                        .padding(24)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            // 適用の確認
            .confirmationDialog(
                "不採用の写真を移動しますか？",
                isPresented: Binding(
                    get: { model.pendingApplyPlan != nil },
                    set: { if !$0 { model.pendingApplyPlan = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingApplyPlan
            ) { plan in
                Button("移動する", role: .destructive) { model.confirmApply(plan) }
                Button("キャンセル", role: .cancel) {}
            } message: { plan in
                let b = model.breakdown(of: plan)
                Text("不採用のコマと、連写で採用しなかったコマを \(ApplyEngine.rejectedFolderName) に移します。\n不採用 \(b.rejected) コマ・連写で未採用 \(b.unpicked) コマ（JPG \(plan.jpgCount) 枚・ARW \(plan.arwCount) 枚）。「適用を取り消す」で元に戻せます。")
            }
            // 取り消しの確認
            .confirmationDialog(
                "適用を取り消しますか？",
                isPresented: Binding(
                    get: { model.pendingUndoRecord != nil },
                    set: { if !$0 { model.pendingUndoRecord = nil } }),
                titleVisibility: .visible,
                presenting: model.pendingUndoRecord
            ) { record in
                Button("元に戻す") { model.confirmUndoApply(record) }
                Button("キャンセル", role: .cancel) {}
            } message: { record in
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) に移動した \(record.moves.count) ファイルを元の場所へ戻します。")
            }
            // 通知
            .alert(
                "お知らせ",
                isPresented: Binding(
                    get: { model.notice != nil },
                    set: { if !$0 { model.notice = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(model.notice ?? "")
            }
            // 失敗一覧
            .sheet(item: $model.failureReport) { report in
                FailureListSheet(report: report)
            }
    }
}

extension View {
    func applyFlow(_ model: BrowserModel) -> some View {
        modifier(ApplyFlowModifier(model: model))
    }
}

/// 処理できなかったファイルの一覧
private struct FailureListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: FailureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(report.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(report.summary)
                .foregroundStyle(.secondary)
            List(report.failures, id: \.self) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.path).monospaced()
                    Text(failure.reason).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }
}

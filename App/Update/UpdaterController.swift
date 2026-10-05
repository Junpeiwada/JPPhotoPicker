import SwiftUI
import Sparkle

/// アプリ内の自動更新（Sparkle）の入り口。
///
/// 更新フィード（SUFeedURL）と署名の検証鍵（SUPublicEDKey）は Info.plist に置く。
/// 値の正本は project.yml。
///
/// 「起動時に確認するか」は Sparkle 自身が UserDefaults に持つ（`automaticallyChecksForUpdates`）。
/// アプリ側で別に持つと食い違うので、読み書きはどちらも updater 経由にする。
@MainActor
@Observable
final class UpdaterController {
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// 設定画面のトグルに出す値（Sparkle の値の写し。書き込みは Sparkle にも反映する）
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// 最後に確認した時刻（未確認なら nil）。設定画面を開いたときに `refresh()` で読み直す
    private(set) var lastUpdateCheckDate: Date?

    init(model: BrowserModel) {
        delegate.model = model
        // 更新ダイアログ・進捗・再起動は Sparkle の標準 UI をそのまま使う
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate

        // Sparkle の定期確認は「前回から SUScheduledCheckInterval 経過したとき」だけなので、
        // 起動のたびに確認するため、ここで明示的に裏で確認する。更新があればダイアログが出る
        #if !DEBUG
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
        #endif
    }

    /// メニュー「アップデートを確認…」から呼ぶ。「最新です」も含め結果は Sparkle の UI が出す
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func refresh() {
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
        if automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates {
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        }
    }
}

/// Sparkle の判断に割り込む。
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var model: BrowserModel?

    /// DEBUG ビルドでは裏での確認をしない（開発中のビルドが配布版に置き換わらないように）。
    /// メニューから手動で確認したときだけ通す
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        if updateCheck == .updatesInBackground {
            throw NSError(domain: "JPPhotoPicker.Updater", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "DEBUG ビルドでは自動の更新確認を行いません",
            ])
        }
        #endif
    }

    /// 適用・取り消しでファイルを移動している途中は、更新後の再起動を処理が終わるまで待たせる
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let model, model.isBusy else { return false }
        model.whenIdle { installHandler() }
        return true
    }
}

/// アプリメニューの「JPPhotoPicker について」の下に置く
struct UpdateCommands: Commands {
    let updater: UpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("アップデートを確認…") { updater.checkForUpdates() }
        }
    }
}

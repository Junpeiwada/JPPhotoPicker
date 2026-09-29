import SwiftUI
import AppKit
import CoreGraphics
import PhotoPickerCore

/// 並べ替え後の 1 コマ（フィルムストリップ・コマ送り用の平らな並び）
struct BrowserEntry: Identifiable, Hashable {
    var id: String { item.id }
    let item: PhotoItem
    let groupIndex: Int
    /// グループ内の位置（0 始まり）
    let positionInGroup: Int
    let groupCount: Int
    let isBurst: Bool
}

/// 選別画面の状態。判定・コマ送り・ズーム・画像表示・保存をまとめる。
@MainActor
@Observable
final class BrowserModel {
    // MARK: フォルダ
    private(set) var folderURL: URL?
    private(set) var isLoading = false
    /// 一覧を出した後、メタデータを読んでいる間は true（連写グループは読み終えてから組む）
    private(set) var isLoadingMetadata = false
    /// メタデータを読み終えたコマ数
    private(set) var metadataLoadedCount = 0
    private(set) var errorMessage: String?

    // MARK: コマ
    private(set) var groups: [PhotoGroup] = []
    private(set) var entries: [BrowserEntry] = []
    private(set) var currentIndex = 0
    private var groupStarts: [Int] = []
    private var indexByID: [String: Int] = [:]

    // MARK: 判定
    private(set) var book = DecisionBook()
    private(set) var pickedCount = 0
    private(set) var rejectedCount = 0

    // MARK: ズーム・表示
    private(set) var zoom = ZoomState()
    /// PreviewView が更新する（ポイント）
    var viewSize: CGSize = .zero
    /// PreviewView が更新する（Retina は 2）
    var backingScale: Double = 2
    /// PreviewView が更新する。ツールバーの高さ（ポイント）。全体表示はこの下に収める
    private(set) var topInset: CGFloat = 0
    private(set) var currentFocus: FocusGeometry = .centered
    /// 大プレビュー（未読み込みの間はサムネイル）
    private(set) var displayPreview: CGImage?
    /// 拡大時の本体。デコード完了まで nil
    private(set) var displayBody: CGImage?

    var showFocusFrame: Bool {
        didSet { UserDefaults.standard.set(showFocusFrame, forKey: PreferenceKey.showFocusFrame) }
    }
    /// 情報パネル（EXIF）を表示するか。I キー・ツールバーのボタンで切り替える
    var showInfo: Bool {
        didSet { UserDefaults.standard.set(showInfo, forKey: PreferenceKey.showInfo) }
    }
    /// 情報パネルの内容（コマ ID → 情報）。表示したコマの分だけ持つ
    private(set) var infoCache: [String: PhotoInfo] = [:]
    private static let infoCacheLimit = 64

    let pipeline = ImagePipeline()

    // MARK: 適用・取り消しの UI 状態
    /// 確認ダイアログに出す移動予定（nil でなければ表示中）
    var pendingApplyPlan: ApplyPlan?
    /// 取り消しの確認ダイアログに出す記録
    var pendingUndoRecord: ApplyRecord?
    /// 短い通知（アラート）。nil でなければ表示中
    var notice: String?
    /// フォルダ選択（fileImporter）の表示中
    var isImporterPresented = false
    /// 失敗一覧のシート
    var failureReport: FailureReport?
    /// 適用・取り消しの実行中はメッセージが入る（操作を無効化する）
    private(set) var busyMessage: String?

    /// 保存ファイルを読み取り専用として扱う（保存しない）
    private(set) var isSessionReadOnly = false
    /// 直近の保存が失敗している
    private(set) var saveFailed = false
    private var saveFailureNotified = false
    private var saveGeneration = 0
    private var hasPendingSave = false
    /// 適用・取り消しの完了を待つ呼び出し（終了時の確認から使う）
    private var idleCallbacks: [() -> Void] = []

    private var session = SessionData()
    private var saver: SessionSaver?
    private var saveTask: Task<Void, Never>?
    private var pinchStartScale: Double?
    private var previewTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var currentMetadataTask: Task<Void, Never>?

    init() {
        PreferenceKey.register()
        showFocusFrame = UserDefaults.standard.bool(forKey: PreferenceKey.showFocusFrame)
        showInfo = UserDefaults.standard.bool(forKey: PreferenceKey.showInfo)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    // MARK: 参照用

    var hasFolder: Bool { folderURL != nil }
    var hasEntries: Bool { !entries.isEmpty }
    /// 適用・取り消しの実行中（操作を受け付けない）
    var isBusy: Bool { busyMessage != nil }
    /// 直近の適用を取り消せるか
    var canUndoApply: Bool {
        !isBusy && !isLoading && !isLoadingMetadata && !isSessionReadOnly && session.applied.last != nil
    }
    /// 適用できるか（読み取り専用のセッションでは適用しない。記録を保存できず、取り消せなくなるため。
    /// メタデータの読み込み中も、連写グループが決まらず移動対象を決められないので適用しない）
    var canApply: Bool { hasEntries && !isBusy && !isSessionReadOnly && !isLoadingMetadata }
    /// 適用が使えない理由（ヘルプ表示用）。使えるなら nil
    var applyDisabledReason: String? {
        if isSessionReadOnly {
            return "このフォルダは読み取り専用で開いているため、適用できません（記録を保存できず、取り消せなくなります）"
        }
        if isLoadingMetadata { return "写真の情報を読み込み中のため、まだ適用できません（連写グループが決まっていません）" }
        return nil
    }
    var folderName: String? { folderURL?.lastPathComponent }

    var currentEntry: BrowserEntry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }
    var currentItem: PhotoItem? { currentEntry?.item }
    var currentDecision: Decision {
        currentItem.map { book.decision(for: $0.id) } ?? .undecided
    }

    func decision(for item: PhotoItem) -> Decision { book.decision(for: item.id) }

    var remainingCount: Int { max(entries.count - pickedCount - rejectedCount, 0) }

    var progressText: String {
        guard hasEntries else { return isLoading ? "読み込み中…" : "" }
        var text = "採用 \(pickedCount) ・ 不採用 \(rejectedCount) ・ 残り \(remainingCount)"
        if isSessionReadOnly {
            text += " ・ 読み取り専用（保存されません）"
        } else if saveFailed {
            text += " ・ 保存できていません"
        }
        if isLoadingMetadata { text += " ・ 読み込み中 \(metadataLoadedCount)/\(entries.count)" }
        return text
    }

    var canUndo: Bool { !isBusy && book.history.canUndo }
    var canRedo: Bool { !isBusy && book.history.canRedo }

    /// 確認ダイアログ・通知・失敗一覧・フォルダ選択のいずれかが出ている間は、判定・移動・メニューを受け付けない
    var isModalPresented: Bool {
        pendingApplyPlan != nil || pendingUndoRecord != nil || failureReport != nil || notice != nil || isImporterPresented
    }
    /// 判定・移動などの操作を受け付けるか
    private var isInteractive: Bool { !isBusy && !isModalPresented }

    /// 表示向きの画像の大きさ（画素）。メタデータ（画像サイズ＋Orientation）を優先し、
    /// 無いときだけ読み込み済みの画像から推定する。デコード済みかどうかに結果が左右されない。
    func pixelSize(of item: PhotoItem) -> CGSize {
        if let m = item.metadata, let w = m.imageWidth, let h = m.imageHeight, w > 0, h > 0 {
            return (5...8).contains(m.orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        if let b = pipeline.cached(.body, for: item) { return CGSize(width: b.width, height: b.height) }
        if let p = pipeline.cached(.preview, for: item) { return CGSize(width: p.width, height: p.height) }
        return .zero
    }

    /// 今のコマの表示向きの大きさ（画素）
    var currentPixelSize: CGSize {
        guard let item = currentItem else { return .zero }
        let size = pixelSize(of: item)
        if size != .zero { return size }
        if let body = displayBody { return CGSize(width: body.width, height: body.height) }
        if let p = displayPreview { return CGSize(width: p.width, height: p.height) }
        return .zero
    }

    private func viewport(for item: PhotoItem) -> ZoomViewport {
        ZoomViewport(viewSize: viewSize, imagePixelSize: pixelSize(of: item), backingScale: backingScale,
                     fitTopInset: topInset)
    }

    var geometry: ViewportGeometry {
        ViewportGeometry(viewSize: viewSize, imagePixelSize: currentPixelSize, backingScale: backingScale, zoom: zoom,
                         topInset: topInset)
    }

    private var prefetchCount: Int {
        max(0, UserDefaults.standard.integer(forKey: PreferenceKey.prefetchCount))
    }

    // MARK: フォルダを開く

    /// フォルダ選択を出す（実体は BrowserView の `fileImporter`）
    func chooseFolder() {
        guard isInteractive else { return }
        isImporterPresented = true
    }

    /// ドロップされた URL を開く（フォルダならそのフォルダ、ファイルなら親フォルダ）
    @discardableResult
    func open(dropped urls: [URL]) -> Bool {
        guard isInteractive, let url = urls.first else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        open(folder: isDir.boolValue ? url : url.deletingLastPathComponent())
        return true
    }

    /// フォルダを開く。`id` があれば、そのコマを選んだ状態にする（無ければ最初の未判定コマ）。
    /// `carrying` があれば、読み直した後でディスクの内容の代わりにそのセッション（判定・適用の記録）を使う。
    /// 保存に失敗したまま読み直しても、メモリ上の判定や取り消しの結果を失わないため。
    func open(folder: URL, selecting id: String? = nil, carrying: SessionData? = nil) {
        flushSave()
        // 保存できていない内容を引き継ぐときは、読み直した後で保存し直す
        let carryUnsaved = carrying != nil && hasPendingSave
        pipeline.removeAll()
        infoCache = [:]
        openTask?.cancel()
        metadataTask?.cancel()
        currentMetadataTask?.cancel()
        isLoadingMetadata = false
        metadataLoadedCount = 0
        previewTask?.cancel()
        bodyTask?.cancel()
        saveTask?.cancel()
        saveTask = nil
        hasPendingSave = false
        folderURL = folder
        errorMessage = nil
        isLoading = true
        groups = []
        entries = []
        groupStarts = []
        indexByID = [:]
        book = DecisionBook()
        pickedCount = 0
        rejectedCount = 0
        currentIndex = 0
        zoom = ZoomState()
        pinchStartScale = nil
        displayPreview = nil
        displayBody = nil
        currentFocus = .centered
        session = SessionData()
        isSessionReadOnly = false
        saveFailed = false
        saveFailureNotified = false
        let store = SessionStore(folder: folder)
        saver = SessionSaver(store: store)

        // 専用の子タスクを作らず、`@concurrent` の読み込みを直接待つ（キャンセルがそのまま伝わる）
        openTask = Task { [weak self] in
            let outcome = await SessionIO.load(folder: folder, store: store)
            guard !Task.isCancelled, let outcome, let self, self.folderURL == folder else { return }
            self.finishOpening(outcome, folder: folder, selecting: id, carrying: carrying, carryUnsaved: carryUnsaved)
            if outcome.scanError == nil, !outcome.items.isEmpty { self.startLoadingMetadata(outcome.items, folder: folder) }
        }
    }

    /// 一覧を出した後で全コマのメタデータを読み、読み終えたら連写グループを組み直す。
    /// 外付け HDD の数千枚では 1 分ほどかかるので、その間も選別できるよう一覧を先に出している。
    private func startLoadingMetadata(_ items: [PhotoItem], folder: URL) {
        isLoadingMetadata = true
        metadataLoadedCount = 0
        let progress: @Sendable (Int) -> Void = { [weak self] done in
            Task { @MainActor in
                guard let self, self.isLoadingMetadata, self.folderURL == folder else { return }
                self.metadataLoadedCount = max(self.metadataLoadedCount, done)
            }
        }
        metadataTask = Task { [weak self] in
            let loaded = await SessionIO.loadMetadata(items: items, progress: progress)
            guard !Task.isCancelled, let loaded, let self, self.folderURL == folder else { return }
            self.finishLoadingMetadata(loaded)
        }
    }

    /// 読み終えたメタデータで連写グループを組み直す。今のコマは ID で選び直し、ズームは保つ。
    private func finishLoadingMetadata(_ items: [PhotoItem]) {
        currentMetadataTask?.cancel()
        let currentID = currentItem?.id
        installGroups(BurstGrouper.group(items))
        if let currentID, let i = indexByID[currentID] { currentIndex = i }
        isLoadingMetadata = false
        metadataLoadedCount = items.count
        guard let e = currentEntry else { return }
        currentFocus = focus(of: e.item)
        reclamp()
        prefetch()
    }

    /// メタデータの読み込み中に、表示中のコマのメタデータだけ先に読んで差し替える（フォーカス枠と画像の大きさのため）
    private func loadCurrentMetadataIfNeeded() {
        currentMetadataTask?.cancel()
        guard isLoadingMetadata, let item = currentItem, item.metadata == nil else { return }
        let id = item.id
        currentMetadataTask = Task { [weak self] in
            let metadata = await SessionIO.readMetadata(item)
            guard !Task.isCancelled, let metadata, let self, self.isLoadingMetadata,
                  let i = self.indexByID[id], self.entries[i].item.metadata == nil else { return }
            let old = self.entries[i]
            var patched = old.item
            patched.metadata = metadata
            self.entries[i] = BrowserEntry(item: patched, groupIndex: old.groupIndex, positionInGroup: old.positionInGroup,
                                           groupCount: old.groupCount, isBurst: old.isBurst)
            guard self.currentItem?.id == id else { return }
            self.currentFocus = self.focus(of: patched)
            self.reclamp()
        }
    }

    /// グループから、平らなコマの並びと検索用の表を作り直す
    private func installGroups(_ groups: [PhotoGroup]) {
        self.groups = groups
        var entries: [BrowserEntry] = []
        var starts: [Int] = []
        for g in groups {
            starts.append(entries.count)
            for (i, item) in g.items.enumerated() {
                entries.append(BrowserEntry(item: item, groupIndex: g.id, positionInGroup: i,
                                            groupCount: g.items.count, isBurst: g.isBurst))
            }
        }
        self.entries = entries
        self.groupStarts = starts
        self.indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
    }

    private func finishOpening(_ outcome: FolderLoadOutcome, folder: URL, selecting id: String?,
                               carrying: SessionData?, carryUnsaved: Bool) {
        session = carrying ?? outcome.session
        isSessionReadOnly = outcome.readOnly
        // メタデータはまだ無いので、すべて単写としてファイル名順に並ぶ（読み終えてから組み直す）
        installGroups(BurstGrouper.group(outcome.items))
        // 今のフォルダに無いコマの判定は捨てず保存データには残す（book には存在するものだけ入れる）
        let known = session.decisions.filter { indexByID[$0.key] != nil }
        book = DecisionBook(decisions: known)
        recount()
        isLoading = false
        errorMessage = outcome.scanError

        var messages: [String] = []
        if let warning = outcome.sessionWarning { messages.append(warning) }

        // 前回の適用が途中で終わっていたら、記録を取り込んで保存し、成功したらジャーナルを片付ける
        switch outcome.recovery {
        case .none:
            break
        case .recovered(let record):
            // 引き継いだセッションに同じ記録が既にあれば追加されない（その場合は知らせない）
            let added = session.appendApplied(record)
            if persist() {
                ApplyEngine(folder: folder).clearJournal()
                if added {
                    messages.append("前回の適用が途中で終わっていたため、移動済みの \(record.moves.count) ファイルの記録を復旧しました。「適用を取り消す」で元に戻せます。")
                }
            } else if added {
                messages.append("前回の適用が途中で終わっていました（移動済み \(record.moves.count) ファイル）。記録を保存できなかったため、次に開いたときにもう一度復旧します。")
            }
        case .broken(let backup):
            messages.append("前回の適用の記録が壊れていたため、\(backup.lastPathComponent) に退避しました。"
                + "この適用で \(ApplyEngine.rejectedFolderName) に移したファイルは「適用を取り消す」で戻せない可能性があります。"
                + "必要なら \(ApplyEngine.rejectedFolderName) フォルダから手で戻してください。")
        case .unreadable(let reason):
            messages.append("前回の適用の記録を確認できませんでした（\(reason)）。"
                + "取り消せない適用が残っている可能性があります。\(ApplyEngine.rejectedFolderName) フォルダを確認してください。"
                + "記録が残っている間は、新しい適用はできません。")
        }
        // 保存できていなかった内容を引き継いだときは、読み直した後で保存し直す
        if carryUnsaved, !isSessionReadOnly { scheduleSave() }

        // 続きから再開: 指定のコマ、無ければ最初の未判定コマへ
        if let id, let i = indexByID[id] {
            currentIndex = i
        } else {
            currentIndex = entries.firstIndex { book.decision(for: $0.id) == .undecided } ?? 0
        }
        zoom = ZoomState()
        refreshCurrent()
        if !messages.isEmpty { post(notice: messages.joined(separator: "\n\n")) }
    }

    /// 通知を出す。すでに出ていれば続けて表示する。
    private func post(notice text: String) {
        if let current = notice { notice = current + "\n\n" + text } else { notice = text }
    }

    // MARK: コマ送り

    func select(index: Int) { move(to: index) }
    func select(id: String) { if let i = indexByID[id] { move(to: i) } }
    func next() { move(to: currentIndex + 1) }
    func previous() { move(to: currentIndex - 1) }

    func nextGroup() {
        guard let e = currentEntry, e.groupIndex + 1 < groupStarts.count else { return }
        move(to: groupStarts[e.groupIndex + 1])
    }

    func previousGroup() {
        guard let e = currentEntry, e.groupIndex > 0 else { return }
        move(to: groupStarts[e.groupIndex - 1])
    }

    private func move(to newIndex: Int) {
        guard isInteractive, entries.indices.contains(newIndex), newIndex != currentIndex else { return }
        let old = currentEntry
        currentIndex = newIndex
        guard let new = currentEntry else { return }
        currentFocus = focus(of: new.item)
        // 移り先のコマの画像の大きさ（メタデータ由来）でクランプする
        var z = zoom
        z.didMoveToItem(sameGroup: old?.groupIndex == new.groupIndex, focus: currentFocus.center,
                        viewport: viewport(for: new.item))
        applyZoom(z, refreshImages: false)
        refreshDisplay()
        prefetch()
        loadCurrentMetadataIfNeeded()
    }

    // MARK: 情報パネル

    /// 情報パネルの表示を切り替える
    func toggleInfo() { showInfo.toggle() }

    /// 情報パネルに出すコマの情報を読む（情報パネルの .task から呼ぶ。読み済みなら何もしない）
    func loadInfo(for item: PhotoItem) async {
        guard infoCache[item.id] == nil, let info = await SessionIO.readInfo(item), !Task.isCancelled else { return }
        if infoCache.count >= Self.infoCacheLimit { infoCache.removeAll(keepingCapacity: true) }
        infoCache[item.id] = info
    }

    private func focus(of item: PhotoItem) -> FocusGeometry {
        item.metadata.map { FocusGeometry(metadata: $0) } ?? .centered
    }

    // MARK: 判定

    /// 今のコマの判定を切り替える（進まない）。同じ判定なら未判定に戻す。
    func toggleDecision(_ decision: Decision) {
        guard isInteractive, let item = currentItem else { return }
        book.set(currentDecision == decision ? .undecided : decision, for: item.id)
        changed()
    }

    /// 判定の解除（進まない）
    func clearDecision() {
        guard isInteractive, let item = currentItem else { return }
        book.set(.undecided, for: item.id)
        changed()
    }

    func undo() {
        guard isInteractive, let change = book.undo() else { return }
        changed()
        if let i = indexByID[change.itemID] { move(to: i) }
    }

    func redo() {
        guard isInteractive, let change = book.redo() else { return }
        changed()
        if let i = indexByID[change.itemID] { move(to: i) }
    }

    private func changed() {
        recount()
        scheduleSave()
    }

    private func recount() {
        var p = 0, r = 0
        for d in book.decisions.values {
            if d == .picked { p += 1 } else if d == .rejected { r += 1 }
        }
        pickedCount = p
        rejectedCount = r
    }

    // MARK: 保存

    private func currentSession() -> SessionData {
        // 開いていない（別フォルダ由来の）判定も失わないよう、読み込み時の値に現在の判定を重ねる
        var s = session
        var decisions = s.decisions.filter { indexByID[$0.key] == nil }
        for (k, v) in book.decisions { decisions[k] = v }
        s.decisions = decisions
        return s
    }

    /// 少し待ってから保存する（連続した判定をまとめる）。書き込みは専用の直列ロックの下で世代順に行う。
    private func scheduleSave() {
        guard let saver, !isSessionReadOnly else { return }
        saveGeneration += 1
        let generation = saveGeneration
        let data = currentSession()
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let error = await SessionIO.write(saver, data, generation: generation)
            // 保存中にフォルダが切り替わっていたら、結果を今のフォルダに反映しない
            guard let self, self.saver === saver else { return }
            if let error {
                self.handleSaveFailure(error)
                // 失敗したら、終了時の flushSave でもう一度試せるよう保留に戻す
                if !self.isSessionReadOnly { self.hasPendingSave = true }
            } else {
                if generation == self.saveGeneration { self.hasPendingSave = false }
                self.handleSaveSuccess()
            }
        }
    }

    /// 保留中の保存をすぐ書き込む（フォルダを切り替えるとき・終了時）
    func flushSave() {
        guard hasPendingSave else { return }
        saveTask?.cancel()
        saveTask = nil
        hasPendingSave = false
        persist()
    }

    /// 今の状態をすぐ書き込む（同期）。成功したら true。読み取り専用のときは書かず false。
    @discardableResult
    private func persist() -> Bool {
        guard let saver, !isSessionReadOnly else { return false }
        saveTask?.cancel()
        saveTask = nil
        hasPendingSave = false
        saveGeneration += 1
        do {
            try saver.write(currentSession(), generation: saveGeneration)
            handleSaveSuccess()
            return true
        } catch {
            handleSaveFailure(error)
            // 書けなかった内容は、終了時・フォルダ切り替え時の flushSave でもう一度試す
            hasPendingSave = !isSessionReadOnly
            return false
        }
    }

    private func handleSaveSuccess() {
        saveFailed = false
        saveFailureNotified = false
    }

    /// 保存失敗。最初の 1 回だけ通知し、以後は subtitle に控えめに出す。
    private func handleSaveFailure(_ error: any Error) {
        if error is SessionStoreError {
            // 新しい版で作られたファイルは上書きしない
            if !isSessionReadOnly {
                isSessionReadOnly = true
                post(notice: (error as? LocalizedError)?.errorDescription ?? "保存できません。")
            }
            return
        }
        saveFailed = true
        if !saveFailureNotified {
            saveFailureNotified = true
            post(notice: "\(SessionStore.fileName) を保存できませんでした（\(error.localizedDescription)）。判定はこの画面には残りますが、保存されていません。")
        }
    }

    // MARK: ズーム操作

    func toggleZoom() {
        guard isInteractive, let item = currentItem, viewport(for: item).isValid else { return }
        var z = zoom
        z.pressZ(focus: currentFocus.center, viewport: viewport(for: item))
        applyZoom(z)
    }

    func resetZoom() {
        guard isInteractive else { return }
        var z = zoom
        z.escape()
        applyZoom(z)
    }

    func moveToFocus() {
        guard isInteractive, let item = currentItem, viewport(for: item).isValid else { return }
        var z = zoom
        z.moveToFocus(focus: currentFocus.center, viewport: viewport(for: item))
        applyZoom(z)
    }

    func click(atViewPoint p: CGPoint) {
        guard isInteractive else { return }
        let g = geometry
        guard g.isValid else { return }
        var z = zoom
        z.click(at: g.normalizedPoint(forViewPoint: p), viewport: g.viewport)
        applyZoom(z)
    }

    /// 画像を `delta`（ポイント、y 下向き）だけ動かす
    func pan(contentDelta delta: CGSize) {
        guard isInteractive, !zoom.isFit else { return }
        let g = geometry
        let size = g.displaySize
        guard size.width > 0, size.height > 0 else { return }
        var z = zoom
        z.pan(dx: -Double(delta.width / size.width), dy: -Double(delta.height / size.height), viewport: g.viewport)
        applyZoom(z)
    }

    /// ピンチの開始。今の実効倍率（全体表示なら fitScale）を控える。
    func beginPinch() {
        let g = geometry
        pinchStartScale = g.isValid ? g.effectiveScale : nil
    }

    /// ピンチ。`magnification` はジェスチャー開始からの累積倍率、`anchorViewPoint` は指の位置（ビュー座標）。
    func pinch(magnification: Double, anchorViewPoint p: CGPoint) {
        guard isInteractive else { return }
        let g = geometry
        guard g.isValid, magnification > 0 else { return }
        let start = pinchStartScale ?? g.effectiveScale
        pinchStartScale = start
        var z = zoom
        z.pinch(to: ZoomState.pinchTarget(startScale: start, magnification: magnification),
                anchor: g.normalizedPoint(forViewPoint: p), viewport: g.viewport)
        applyZoom(z)
    }

    func endPinch() { pinchStartScale = nil }

    /// PreviewView から大きさ・倍率（displayScale）が変わったとき
    /// `topInset` はツールバーの高さ。全体表示はその下に収める
    func viewportChanged(size: CGSize, scale: Double, topInset: CGFloat) {
        viewSize = size
        backingScale = scale
        self.topInset = topInset
        reclamp()
    }

    /// 今のコマの大きさで中心をクランプし直す
    private func reclamp() {
        guard !zoom.isFit, currentItem != nil else { return }
        var z = zoom
        z.clampCenter(viewport: geometry.viewport)
        applyZoom(z)
    }

    /// 反映し、拡大の出入りで本体の読み込みを切り替える。クランプは各操作（`viewport:` 付き）が済ませている。
    private func applyZoom(_ new: ZoomState, refreshImages: Bool = true) {
        let wasFit = zoom.isFit
        guard new != zoom else { return }
        zoom = new
        if refreshImages, wasFit != new.isFit { refreshBody(); prefetch() }
    }

    // MARK: 画像表示

    /// 今のコマの表示を作り直す（フォルダを開いたとき）
    private func refreshCurrent() {
        guard let e = currentEntry else { return }
        currentFocus = focus(of: e.item)
        refreshDisplay()
        prefetch()
        loadCurrentMetadataIfNeeded()
    }

    private func refreshDisplay() {
        guard let item = currentItem else {
            displayPreview = nil
            displayBody = nil
            return
        }
        previewTask?.cancel()
        if let p = pipeline.cached(.preview, for: item) {
            displayPreview = p
        } else {
            // 読み込み中は、あればサムネイルを仮表示する
            displayPreview = pipeline.cached(.thumbnail, for: item)
            let id = item.id
            previewTask = Task { [weak self, pipeline] in
                async let thumb = pipeline.load(.thumbnail, for: item)
                let preview = await pipeline.load(.preview, for: item)
                guard !Task.isCancelled, let self, self.currentItem?.id == id else { return }
                if let preview {
                    self.displayPreview = preview
                    self.reclamp()
                } else if self.displayPreview == nil {
                    let t = await thumb
                    // サムネイルを待つ間にコマが変わっていないか確認する
                    guard !Task.isCancelled, self.currentItem?.id == id, self.displayPreview == nil else { return }
                    self.displayPreview = t
                    self.reclamp()
                }
            }
        }
        refreshBody()
    }

    private func refreshBody() {
        bodyTask?.cancel()
        guard let item = currentItem, !zoom.isFit else {
            displayBody = nil
            return
        }
        if let b = pipeline.cached(.body, for: item) {
            displayBody = b
            return
        }
        displayBody = nil
        let id = item.id
        bodyTask = Task { [weak self, pipeline] in
            let body = await pipeline.load(.body, for: item)
            guard !Task.isCancelled, let self, self.currentItem?.id == id, !self.zoom.isFit else { return }
            self.displayBody = body
            self.reclamp()
        }
    }

    // MARK: 先読み

    private func prefetch() {
        guard currentEntry != nil else { return }
        let n = prefetchCount
        var order: [PhotoItem] = []
        if n > 0 {
            for d in 1...n {
                if entries.indices.contains(currentIndex + d) { order.append(entries[currentIndex + d].item) }
                if entries.indices.contains(currentIndex - d) { order.append(entries[currentIndex - d].item) }
            }
        }
        pipeline.prefetch(.preview, items: order)

        // 拡大中は、グループ内の前後の本体も先読みする。全体表示のときも呼んで、範囲外の本体ジョブを取り消す
        var neighbors: [PhotoItem] = []
        if !zoom.isFit, let e = currentEntry {
            if e.positionInGroup + 1 < e.groupCount { neighbors.append(entries[currentIndex + 1].item) }
            if e.positionInGroup > 0 { neighbors.append(entries[currentIndex - 1].item) }
        }
        pipeline.prefetch(.body, items: neighbors)
    }

    // MARK: 適用（一括移動）と取り消し

    /// 移動予定の内訳。不採用にしたコマと、連写で採用しなかった（不採用ではない）コマ
    func breakdown(of plan: ApplyPlan) -> (rejected: Int, unpicked: Int) {
        var rejected = 0, unpicked = 0
        for c in plan.candidates {
            if book.decision(for: c.id) == .rejected { rejected += 1 } else { unpicked += 1 }
        }
        return (rejected, unpicked)
    }

    /// 「適用」。移動予定を作り、確認ダイアログを出す（0 件ならその旨を知らせる）。
    func requestApply() {
        guard hasEntries, isInteractive else { return }
        if let reason = applyDisabledReason {
            notice = reason
            return
        }
        let plan = ApplyEngine.plan(groups: groups, decisions: book.decisions)
        if plan.isEmpty {
            notice = "移動するファイルはありません"
        } else {
            pendingApplyPlan = plan
        }
    }

    /// 確認後に `_rejected` へ移す。実行はバックグラウンド。
    /// 確認したときの予定と今の判定から作り直した予定が違えば、実行せずダイアログを出し直す。
    func confirmApply(_ plan: ApplyPlan) {
        guard let folder = folderURL, !isBusy, !isSessionReadOnly else { return }
        let fresh = ApplyEngine.plan(groups: groups, decisions: book.decisions)
        guard fresh == plan else {
            pendingApplyPlan = nil
            // ダイアログの閉じる処理が終わってから出し直す
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.isBusy else { return }
                if fresh.isEmpty { self.notice = "移動するファイルはありません" } else { self.pendingApplyPlan = fresh }
            }
            return
        }
        pendingApplyPlan = nil
        busyMessage = "\(ApplyEngine.rejectedFolderName) に移動しています…"
        Task { [weak self] in
            let result = await SessionIO.apply(folder: folder, plan: plan)
            self?.finishApply(result: result, folder: folder)
        }
    }

    private func finishApply(result: ApplyResult, folder: URL) {
        defer { endBusy() }
        guard folderURL == folder else { return }

        // 移動したコマの判定は保存データに残す（取り消して戻したときに判定を復元するため）。
        // 画面の book からは外し、取り消し履歴（DecisionHistory）は空にする。
        session.decisions = currentSession().decisions
        if let record = result.record { session.appendApplied(record) }

        var reopen = false
        var reopenID: String?
        if let record = result.record {
            let movedNames = Set(record.moves.map { ($0.from as NSString).lastPathComponent })
            var removedIDs = Set<String>()
            var partial = false
            for item in entries.map(\.item) {
                let names = item.allURLs.map(\.lastPathComponent)
                let moved = names.filter(movedNames.contains).count
                if moved == names.count { removedIDs.insert(item.id) } else if moved > 0 { partial = true }
            }
            if partial {
                // ペアの片方だけ移ったコマがある（戻し失敗のときだけ起こる。通常はペアそろって移すか、移さない）: 保存してフォルダを読み直す。
                // 今のコマ（全部移って無くなるなら近くの残ったコマ）を選び直す
                reopen = true
                reopenID = nearestSurvivorID(excluding: removedIDs)
            } else {
                removeItems(ids: removedIDs)
            }
            // 記録を保存できたら、適用のジャーナルを片付ける（保存できなければ残して、次回の起動で復旧する）
            if persist() { ApplyEngine(folder: folder).clearJournal() }
        }
        showFailures(result.failures,
                     title: "一部のファイルを移動できませんでした",
                     done: result.movedCount, doneLabel: "移動しました")
        // 保存に失敗していても、メモリ上の判定と適用の記録を引き継いで読み直す
        if reopen { open(folder: folder, selecting: reopenID, carrying: session) }
    }

    /// 今のコマ、無ければその前後で最も近い、`ids` に入っていないコマの ID
    private func nearestSurvivorID(excluding ids: Set<String>) -> String? {
        guard !entries.isEmpty else { return nil }
        let start = min(max(currentIndex, 0), entries.count - 1)
        for d in 0..<entries.count {
            for i in [start + d, start - d] where entries.indices.contains(i) && !ids.contains(entries[i].id) {
                return entries[i].id
            }
        }
        return nil
    }

    /// 適用・取り消しの実行中を終える。完了待ちの呼び出しがあれば実行する。
    private func endBusy() {
        busyMessage = nil
        let callbacks = idleCallbacks
        idleCallbacks = []
        for c in callbacks { c() }
    }

    /// 適用・取り消しの実行中でなければすぐ、実行中なら終わった後で `body` を呼ぶ
    func whenIdle(_ body: @escaping () -> Void) {
        if isBusy { idleCallbacks.append(body) } else { body() }
    }

    /// 移したコマを一覧から取り除く。今のコマが消えたときは近くの残ったコマへ。
    private func removeItems(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let oldIndex = currentIndex
        let currentID = currentItem?.id
        var survivorsBefore = 0
        for (i, e) in entries.enumerated() where i < oldIndex && !ids.contains(e.id) { survivorsBefore += 1 }

        let remaining = entries.map(\.item).filter { !ids.contains($0.id) }
        installGroups(BurstGrouper.group(remaining))
        book = DecisionBook(decisions: book.decisions.filter { indexByID[$0.key] != nil })
        recount()
        zoom = ZoomState()
        displayBody = nil
        if entries.isEmpty {
            currentIndex = 0
            displayPreview = nil
            errorMessage = "すべての写真を \(ApplyEngine.rejectedFolderName) に移動しました。"
            return
        }
        if let currentID, let i = indexByID[currentID] {
            currentIndex = i
        } else {
            currentIndex = min(survivorsBefore, entries.count - 1)
        }
        refreshCurrent()
    }

    /// 「適用を取り消す」。直近の記録を確認ダイアログに出す。
    func requestUndoApply() {
        guard canUndoApply, isInteractive, let record = session.applied.last else { return }
        pendingUndoRecord = record
    }

    func confirmUndoApply(_ record: ApplyRecord) {
        guard let folder = folderURL, !isBusy else { return }
        pendingUndoRecord = nil
        busyMessage = "元の場所に戻しています…"
        // 取り消し後に、元いたコマを選び直す
        let keepID = currentItem?.id
        Task { [weak self] in
            let result = await SessionIO.undo(folder: folder, record: record)
            self?.finishUndoApply(record: record, result: result, folder: folder, keepID: keepID)
        }
    }

    private func finishUndoApply(record: ApplyRecord, result: UndoResult, folder: URL, keepID: String?) {
        defer { endBusy() }
        guard folderURL == folder else { return }
        session.decisions = currentSession().decisions
        let matched = session.finishUndo(of: record, result: result)
        persist()
        // 戻したコマを含めて読み直す（判定はメモリ上のセッションから復元される）。
        // 保存に失敗しても、取り消した記録がディスクの古い内容で復活しないよう、メモリ上のセッションを引き継ぐ
        open(folder: folder, selecting: keepID, carrying: session)
        if !matched {
            post(notice: "適用の記録が見つからなかったため、フォルダを読み直して状態を合わせました。")
        }
        showFailures(result.failures,
                     title: "一部のファイルを戻せませんでした",
                     done: result.restoredCount, doneLabel: "戻しました")
    }

    private func showFailures(_ failures: [ApplyFailure], title: String, done: Int, doneLabel: String) {
        guard !failures.isEmpty else { return }
        failureReport = FailureReport(
            title: title,
            summary: "\(done) 件を\(doneLabel)。\(failures.count) 件は処理できませんでした。",
            failures: failures)
    }
}

/// 適用・取り消しで処理できなかったファイルの一覧（シート表示用）
struct FailureReport: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let failures: [ApplyFailure]
}

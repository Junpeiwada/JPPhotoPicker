import Foundation

/// 種類: JPG と ARW のペア / JPG だけ / ARW だけ
public enum PhotoKind: String, Sendable, Codable, Hashable {
    case pair
    case jpgOnly
    case arwOnly
}

/// 1 コマ（フォルダ内の 1 つの写真。JPG+ARW ペアなら 1 コマ）
public struct PhotoItem: Sendable, Identifiable, Hashable {
    /// コマ ID = 表示に使うファイル名（JPG があれば JPG、無ければ ARW）。判定の保存キーにもなる
    public let id: String
    /// 拡張子を除いたファイル名
    public let baseName: String
    public let kind: PhotoKind
    public let jpgURL: URL?
    public let arwURL: URL?
    /// ファイル名の末尾の数字列（例: A1_07866 → 7866）。取れなければ nil
    public let fileNumber: Int?
    /// ファイル名（拡張子なし）の末尾の数字列を除いた部分（例: A1_07866 → "A1_"）。連写グループの同一判定に使う
    public let namePrefix: String
    /// メタデータ（未読み取り・読めなかったときは nil）
    public var metadata: PhotoMetadata?

    /// `jpgURL` と `arwURL` の少なくとも一方は非 nil でなければならない（両方 nil は precondition 違反）。
    public init(baseName: String, jpgURL: URL?, arwURL: URL?, metadata: PhotoMetadata? = nil) {
        precondition(jpgURL != nil || arwURL != nil, "PhotoItem には JPG か ARW のどちらかが必要です")
        self.baseName = baseName
        self.jpgURL = jpgURL
        self.arwURL = arwURL
        self.kind = jpgURL != nil ? (arwURL != nil ? .pair : .jpgOnly) : .arwOnly
        self.id = (jpgURL ?? arwURL)?.lastPathComponent ?? baseName
        self.fileNumber = Self.trailingNumber(of: baseName)
        self.namePrefix = Self.prefixBeforeTrailingDigits(of: baseName)
        self.metadata = metadata
    }

    /// 表示・メタデータ読み取りに使う主ファイル（JPG があれば JPG）
    public var primaryURL: URL { jpgURL ?? arwURL! }

    /// 適用時に移す対象のファイル（JPG、ARW の順）
    public var allURLs: [URL] { [jpgURL, arwURL].compactMap { $0 } }

    static func prefixBeforeTrailingDigits(of name: String) -> String {
        var end = name.endIndex
        while end > name.startIndex {
            let prev = name.index(before: end)
            guard name[prev].isASCII, name[prev].isNumber else { break }
            end = prev
        }
        return String(name[..<end])
    }

    static func trailingNumber(of name: String) -> Int? {
        var digits: [Character] = []
        for ch in name.reversed() {
            if ch.isASCII, ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        return Int(String(digits.reversed()))
    }
}

public enum FolderScanner {
    /// フォルダ直下だけを走査し、JPG/ARW をベース名（大文字小文字を区別しない）で対応付ける。
    /// 隠しファイル、サブフォルダ（`_rejected` を含む）は対象外。結果はファイル名順。
    /// メタデータは読まない（`metadata == nil`）。
    public static func scan(folder: URL) throws -> [PhotoItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])

        var jpgs: [String: URL] = [:]
        var arws: [String: URL] = [:]
        var names: [String: String] = [:]   // key → JPG 優先の表示用ベース名
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            let key = base.lowercased()
            switch ext {
            case "jpg", "jpeg":
                if jpgs[key] == nil { jpgs[key] = url; names[key] = base }
            case "arw":
                if arws[key] == nil { arws[key] = url; if names[key] == nil { names[key] = base } }
            default:
                continue
            }
        }

        let keys = Set(jpgs.keys).union(arws.keys)
        return keys
            .map { PhotoItem(baseName: names[$0] ?? $0, jpgURL: jpgs[$0], arwURL: arws[$0]) }
            .sorted { $0.id.compare($1.id, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }
}

public enum PhotoMetadataLoader {
    /// 既定の読み取り: JPG（ペア含む）は `JPEGMetadataReader`、ARW だけは `ARWMetadataReader`
    @Sendable
    public static func defaultReader(_ item: PhotoItem) -> PhotoMetadata? {
        if let jpg = item.jpgURL { return try? JPEGMetadataReader.read(url: jpg) }
        guard let arw = item.arwURL else { return nil }
        return try? ARWMetadataReader.read(url: arw)
    }

    /// 全コマのメタデータを並列に読み、`metadata` を埋めた配列（順序は入力と同じ）を返す。
    ///
    /// 同期 I/O は協調スレッドプールではなく専用の並列キュー（`DispatchQueue.concurrentPerform`）で行い、
    /// `withCheckedContinuation` で待つ。タスクがキャンセルされたら、チャンク（8 コマ）ごとの確認で打ち切り、
    /// 未処理のコマは `metadata == nil` のまま返す。
    /// - Parameter progress: 読み終えた累計コマ数と全コマ数を、チャンクを終えるたびに呼ぶ（任意のスレッドから並行に呼ばれる。
    ///   呼び出しの順序は前後することがあるので、最大値を採用すること。最後は `(total, total)` になる。
    ///   キャンセル時は最後まで呼ばれないことがある）
    public static func load(
        items: [PhotoItem],
        reader: @escaping @Sendable (PhotoItem) -> PhotoMetadata? = PhotoMetadataLoader.defaultReader,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [PhotoItem] {
        guard !items.isEmpty else { return items }
        let state = LoadState(count: items.count)
        let chunk = chunkSize
        let chunkCount = (items.count + chunk - 1) / chunk

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadQueue.async {
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                        if state.isCancelled { return }
                        let lo = c * chunk, hi = min(lo + chunk, items.count)
                        for i in lo..<hi {
                            if state.isCancelled { return }
                            state.store(reader(items[i]), at: i)
                        }
                        let done = state.addCompleted(hi - lo)
                        progress?(done, items.count)
                    }
                    cont.resume()
                }
            }
        } onCancel: {
            state.cancel()
        }

        var result = items
        for i in result.indices { result[i].metadata = state.value(at: i) }
        return result
    }

    private static let chunkSize = 8

    /// 読み込み専用の並列キュー（協調スレッドプールを塞がないため）
    private static let loadQueue = DispatchQueue(
        label: "PhotoPickerCore.metadata-load", qos: .userInitiated, attributes: .concurrent)
}

/// 並列読み込みの共有状態。各コマの書き込み先は重ならない。
private final class LoadState: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<PhotoMetadata?>
    private let count: Int
    private let lock = NSLock()
    private var cancelled = false
    private var completed = 0

    init(count: Int) {
        self.count = count
        storage = .allocate(capacity: count)
        storage.initialize(repeating: nil, count: count)
    }

    deinit {
        storage.deinitialize(count: count)
        storage.deallocate()
    }

    func store(_ m: PhotoMetadata?, at i: Int) { storage[i] = m }

    /// すべてのワーカーの終了後（continuation の再開後）にだけ呼ぶ
    func value(at i: Int) -> PhotoMetadata? { storage[i] }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func addCompleted(_ n: Int) -> Int { lock.withLock { completed += n; return completed } }
}

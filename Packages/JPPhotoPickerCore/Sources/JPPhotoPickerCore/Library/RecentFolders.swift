import Foundation

/// 最近開いたフォルダ 1 件
public struct RecentFolder: Codable, Hashable, Sendable, Identifiable {
    /// 標準化したパス
    public let path: String
    public let openedAt: Date

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var name: String { url.lastPathComponent }
    /// 親フォルダのパス（表示用）
    public var parentPath: String { url.deletingLastPathComponent().path }

    public init(path: String, openedAt: Date) {
        self.path = path
        self.openedAt = openedAt
    }
}

/// 最近開いたフォルダの履歴（新しい順）。同じフォルダは 1 件にまとめ、上限を超えた古いものは捨てる。
public struct RecentFolders: Codable, Hashable, Sendable {
    public static let limit = 10

    public private(set) var items: [RecentFolder] = []

    public init(items: [RecentFolder] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    private enum CodingKeys: String, CodingKey { case items }

    /// 保存済みの履歴が上限を超えていても、上限までしか読まない
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try c.decode([RecentFolder].self, forKey: .items))
    }

    /// 開いたことを記録する（先頭に置く）
    public mutating func record(_ url: URL, at date: Date) {
        let path = Self.normalized(url)
        items.removeAll { $0.path == path }
        items.insert(RecentFolder(path: path, openedAt: date), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ url: URL) {
        let path = Self.normalized(url)
        items.removeAll { $0.path == path }
    }

    /// シンボリックリンクを解決し、末尾の `/` や `.` を除いたパス（同じフォルダを別の書き方で 2 件にしないため）
    static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

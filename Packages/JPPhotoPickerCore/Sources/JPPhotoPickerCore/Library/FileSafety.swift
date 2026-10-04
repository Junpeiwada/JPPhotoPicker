import Foundation

/// 上書きを避けるためのファイル操作の小道具（`SessionStore` と `ApplyEngine` で共有する）
enum FileSafety {
    /// 壊れたリンクも「ある」とみなす（上書きを避けるため）
    static func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// 壊れたファイルの退避先 `<baseName>.broken-yyyyMMdd-HHmmss` を `folder` 直下に作る（ファイルは作らない）。
    /// 既にあれば `-2`、`-3` … と連番を付ける。
    static func brokenDestination(for baseName: String, in folder: URL, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: date)
        var dest = folder.appendingPathComponent("\(baseName).broken-\(stamp)")
        var n = 2
        while exists(dest) {
            dest = folder.appendingPathComponent("\(baseName).broken-\(stamp)-\(n)")
            n += 1
        }
        return dest
    }
}

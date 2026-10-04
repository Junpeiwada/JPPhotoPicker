import Testing
import Foundation
@testable import JPPhotoPickerCore

@Suite("最近開いたフォルダ（RecentFolders）")
struct RecentFoldersTests {
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p, isDirectory: true) }
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test("新しい順に並ぶ")
    func newestFirst() {
        var r = RecentFolders()
        r.record(url("/a"), at: t0)
        r.record(url("/b"), at: t0.addingTimeInterval(1))
        #expect(r.items.map(\.path) == ["/b", "/a"])
    }

    @Test("同じフォルダは先頭へ移り、1 件にまとまる（書き方の違いも同じとみなす）")
    func dedupe() {
        var r = RecentFolders()
        r.record(url("/a"), at: t0)
        r.record(url("/b"), at: t0)
        r.record(url("/x/../a/"), at: t0.addingTimeInterval(5))
        #expect(r.items.map(\.path) == ["/a", "/b"])
        #expect(r.items.first?.openedAt == t0.addingTimeInterval(5))
    }

    @Test("シンボリックリンク経由の同じフォルダは 1 件にまとまる")
    func symlink() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("RecentFoldersTests-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        var r = RecentFolders()
        r.record(real, at: t0)
        r.record(link, at: t0.addingTimeInterval(1))
        #expect(r.items.count == 1)
    }

    @Test("上限を超えたら古いものを捨てる")
    func limit() {
        var r = RecentFolders()
        for i in 0..<(RecentFolders.limit + 3) { r.record(url("/f\(i)"), at: t0) }
        #expect(r.items.count == RecentFolders.limit)
        #expect(r.items.first?.path == "/f\(RecentFolders.limit + 2)")
        #expect(!r.items.contains { $0.path == "/f0" })
    }

    @Test("削除できる")
    func remove() {
        var r = RecentFolders()
        r.record(url("/a"), at: t0)
        r.record(url("/b"), at: t0)
        r.remove(url("/a/"))
        #expect(r.items.map(\.path) == ["/b"])
    }

    @Test("名前と親フォルダ")
    func names() {
        let f = RecentFolder(path: "/Volumes/SD/DCIM/100MSDCF", openedAt: t0)
        #expect(f.name == "100MSDCF")
        #expect(f.parentPath == "/Volumes/SD/DCIM")
    }

    @Test("JSON で保存して戻せる")
    func codable() throws {
        var r = RecentFolders()
        r.record(url("/a"), at: t0)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(RecentFolders.self, from: data) == r)
    }

    @Test("保存済みの履歴が上限を超えていても、上限までしか読まない")
    func decodeTruncatesToLimit() throws {
        let many = (0..<(RecentFolders.limit + 5)).map {
            RecentFolder(path: "/f\($0)", openedAt: t0.addingTimeInterval(Double(-$0)))
        }
        let json = try JSONEncoder().encode(["items": many])
        let r = try JSONDecoder().decode(RecentFolders.self, from: json)
        #expect(r.items.count == RecentFolders.limit)
        #expect(r.items.map(\.path) == many.prefix(RecentFolders.limit).map(\.path))   // 新しい順の先頭を残す
    }
}

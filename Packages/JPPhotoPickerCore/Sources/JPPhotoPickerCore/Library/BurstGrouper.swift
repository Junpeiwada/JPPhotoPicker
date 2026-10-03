import Foundation

/// 並べ替え後の 1 グループ（単写は 1 枚で 1 グループ）
public struct PhotoGroup: Sendable, Identifiable, Hashable {
    /// 並び順の通し番号（0 始まり）
    public let id: Int
    public let items: [PhotoItem]
    /// 連写グループか（単写、および区切った結果 1 コマだけになった連写は false）
    public let isBurst: Bool
    /// 連写の先頭番号（ファイル番号 − SequenceNumber + 1）。取れなければ nil
    public let burstStartNumber: Int?

    public init(id: Int, items: [PhotoItem], isBurst: Bool, burstStartNumber: Int?) {
        self.id = id
        self.items = items
        self.isBurst = isBurst
        self.burstStartNumber = burstStartNumber
    }
}

public enum BurstGrouper {
    /// 撮影時刻順（同時刻はファイル名順、撮影時刻なしは末尾）に並べる。
    public static func sorted(_ items: [PhotoItem]) -> [PhotoItem] {
        items.sorted { a, b in
            switch (a.metadata?.captureDate, b.metadata?.captureDate) {
            case let (x?, y?):
                if x != y { return x < y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return a.id.compare(b.id, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    /// 並べ替えて連写グループにまとめる。
    public static func group(_ items: [PhotoItem]) -> [PhotoGroup] {
        var groups: [[PhotoItem]] = []
        var starts: [Int?] = []
        var burstFlags: [Bool] = []
        var lastSeq = 0
        var lastStart: Int?
        var lastPrefix = ""

        for item in sorted(items) {
            let meta = item.metadata
            guard let meta, meta.isBurstFrame, let seq = meta.sequenceNumber else {
                groups.append([item]); starts.append(nil); burstFlags.append(false)
                continue
            }
            let start = item.fileNumber.map { $0 - seq + 1 }

            var joins = false
            if let last = burstFlags.last, last {
                if let start, let lastStart {
                    // 同じ連写 = ファイル名の接頭辞が同じで、先頭番号も同じ
                    joins = start == lastStart && item.namePrefix == lastPrefix
                } else {
                    // 番号が取れないときは、Seq が 1、または前以下で区切る
                    joins = seq != 1 && seq > lastSeq
                }
            }
            if joins {
                groups[groups.count - 1].append(item)
                if starts[starts.count - 1] == nil { starts[starts.count - 1] = start }
            } else {
                groups.append([item]); starts.append(start); burstFlags.append(true)
            }
            lastSeq = seq
            lastStart = start
            lastPrefix = item.namePrefix
        }

        return groups.enumerated().map { i, items in
            // 区切った結果 1 コマだけの連写は単写として扱う（判定ルールも表示も単写と同じ）
            let burst = burstFlags[i] && items.count > 1
            return PhotoGroup(id: i, items: items, isBurst: burst, burstStartNumber: burst ? starts[i] : nil)
        }
    }
}

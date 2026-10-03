import Foundation

/// 判定（未判定 / 採用 / 不採用）
public enum Decision: String, Sendable, Codable, Hashable, CaseIterable {
    case undecided
    case picked
    case rejected
}

/// 移す対象の 1 コマ
public struct MoveCandidate: Sendable, Hashable, Identifiable {
    /// コマ ID（`PhotoItem.id`）
    public let id: String
    /// 移すファイル（JPG、ARW の順。ペアの ARW も含む）
    public let urls: [URL]
    public let jpgURL: URL?
    public let arwURL: URL?
}

public enum DecisionRules {
    /// 移すかどうか。連写・単写とも「採用以外」を移す。
    public static func shouldMove(decision: Decision) -> Bool {
        decision != .picked
    }

    /// 適用時に移す対象を、グループの並び順で返す。`decisions` に無いコマは未判定。
    public static func moveCandidates(groups: [PhotoGroup], decisions: [String: Decision]) -> [MoveCandidate] {
        var out: [MoveCandidate] = []
        for g in groups {
            for item in g.items {
                let d = decisions[item.id] ?? .undecided
                if shouldMove(decision: d) {
                    out.append(MoveCandidate(id: item.id, urls: item.allURLs,
                                             jpgURL: item.jpgURL, arwURL: item.arwURL))
                }
            }
        }
        return out
    }
}

/// 判定の変更 1 件
public struct DecisionChange: Sendable, Hashable {
    public let itemID: String
    public let from: Decision
    public let to: Decision

    public init(itemID: String, from: Decision, to: Decision) {
        self.itemID = itemID
        self.from = from
        self.to = to
    }
}

/// 判定の一覧と取り消し履歴をまとめたもの（UI の状態として使う）
public struct DecisionBook: Sendable, Equatable {
    /// 未判定のコマは持たない
    public private(set) var decisions: [String: Decision]
    public private(set) var history = DecisionHistory()

    public init(decisions: [String: Decision] = [:]) {
        self.decisions = decisions.filter { $0.value != .undecided }
    }

    public func decision(for id: String) -> Decision { decisions[id] ?? .undecided }

    /// 判定を変更し、履歴に積む。変化が無ければ何もせず nil。
    @discardableResult
    public mutating func set(_ decision: Decision, for id: String) -> DecisionChange? {
        let old = self.decision(for: id)
        guard old != decision else { return nil }
        apply(id, decision)
        let change = DecisionChange(itemID: id, from: old, to: decision)
        history.record(change)
        return change
    }

    /// 取り消す。戻したコマ（`itemID`）を含む変更を返す。
    @discardableResult
    public mutating func undo() -> DecisionChange? {
        guard let c = history.undo() else { return nil }
        apply(c.itemID, c.from)
        return c
    }

    /// やり直す。やり直したコマ（`itemID`）を含む変更を返す。
    @discardableResult
    public mutating func redo() -> DecisionChange? {
        guard let c = history.redo() else { return nil }
        apply(c.itemID, c.to)
        return c
    }

    private mutating func apply(_ id: String, _ d: Decision) {
        if d == .undecided { decisions[id] = nil } else { decisions[id] = d }
    }
}

import Foundation

/// 取り消し / やり直しの履歴。どのコマの変更かも持つ。
public struct DecisionHistory: Sendable, Equatable {
    public private(set) var undoStack: [DecisionChange] = []
    public private(set) var redoStack: [DecisionChange] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 変更を積む（やり直しの履歴は消える）
    public mutating func record(_ change: DecisionChange) {
        undoStack.append(change)
        redoStack.removeAll()
    }

    /// 直近の変更を取り消し対象として返す（呼び出し側が `from` を適用する）
    public mutating func undo() -> DecisionChange? {
        guard let c = undoStack.popLast() else { return nil }
        redoStack.append(c)
        return c
    }

    /// 取り消した変更をやり直し対象として返す（呼び出し側が `to` を適用する）
    public mutating func redo() -> DecisionChange? {
        guard let c = redoStack.popLast() else { return nil }
        undoStack.append(c)
        return c
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
